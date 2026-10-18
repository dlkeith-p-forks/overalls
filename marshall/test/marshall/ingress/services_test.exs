defmodule Marshall.Ingress.ServicesTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Ingress
  alias Marshall.Ingress.{Service, Token}

  test "roles bind service identity and only digests are stored" do
    %{host: host} = Marshall.ComputeFixtures.host_fixture()
    {token, hash} = Token.issue()
    params = %{name: "gateway", role: :gateway, host_id: host.id, token: token}
    assert {:ok, service} = Ingress.configure_service(params, actor: SystemActor.compute())
    assert service.role == :gateway
    assert service.host_id == host.id
    assert {:ok, ^service} = Ingress.configure_service(params, actor: SystemActor.compute())

    assert {:ok, ^service} =
             Ingress.service_identity(%{token: token}, actor: SystemActor.compute())

    assert [stored] = Ledger.read!(Service, id: service.id)
    assert stored.token_hash == hash
    refute Map.has_key?(service, :token_hash)
    assert [version] = Ledger.read!(Service.Version, version_source_id: service.id)
    refute Map.has_key?(version.changes, "token_hash")
    refute Map.has_key?(version.changes, :token_hash)

    assert {:error, _} =
             Ingress.configure_service(%{params | role: :dns, host_id: nil},
               actor: SystemActor.compute()
             )

    assert {:error, _} = Ingress.configure_service(params, actor: Marshall.ComputeFixtures.user())
  end

  test "bootstrap preserves service identity and cannot rotate or revive authority" do
    %{host: host} = Marshall.ComputeFixtures.host_fixture()
    actor = SystemActor.compute()

    for role <- [:gateway, :dns] do
      {token, hash} = Token.issue()
      {other, _} = Token.issue()

      params = %{
        name: "bootstrap-#{role}",
        role: role,
        host_id: if(role == :gateway, do: host.id),
        token: token,
        addresses: if(role == :gateway, do: ["192.0.2.9", "192.0.2.10"], else: [])
      }

      assert {:error, _} =
               Ingress.ensure_service(params, actor: Marshall.ComputeFixtures.user())

      assert {:ok, service} = Ingress.ensure_service(params, actor: actor)

      if role == :gateway do
        assert {:ok, _} =
                 Ingress.publish_host_key(%{token: token, public_key: host_key()}, actor: actor)
      end

      before = Ledger.read!(Service, id: service.id)
      versions = Ledger.read!(Service.Version, version_source_id: service.id)
      assert [%{token_hash: ^hash, generation: 1}] = before

      assert {:ok, ^service} =
               Ingress.ensure_service(%{params | addresses: Enum.reverse(params.addresses)},
                 actor: actor
               )

      for changed <- [
            %{params | token: other},
            %{params | addresses: ["192.0.2.11"]},
            %{params | host_id: Ash.UUID.generate()}
          ] do
        assert {:error, _} = Ingress.ensure_service(changed, actor: actor)
        assert Ledger.read!(Service, id: service.id) == before
        assert Ledger.read!(Service.Version, version_source_id: service.id) == versions
      end

      assert {:ok, _} = Ingress.disable_service(%{id: service.id}, actor: actor)
      disabled = Ledger.read!(Service, id: service.id)
      disabled_versions = Ledger.read!(Service.Version, version_source_id: service.id)

      for credential <- [token, other] do
        assert {:error, _} =
                 Ingress.ensure_service(%{params | token: credential}, actor: actor)
      end

      assert Ledger.read!(Service, id: service.id) == disabled
      assert Ledger.read!(Service.Version, version_source_id: service.id) == disabled_versions
    end
  end

  test "invalid role/host combinations are rejected before enrollment" do
    {token, _} = Token.issue()

    for {role, host_id} <- [
          {:gateway, nil},
          {:gateway, Ash.UUID.generate()},
          {:dns, Ash.UUID.generate()}
        ] do
      assert {:error, _} =
               Ingress.configure_service(
                 %{name: "bad", role: role, host_id: host_id, token: token},
                 actor: SystemActor.compute()
               )
    end

    assert [] = Ledger.read!(Service)
  end

  test "gateway host keys are immutable per generation and cleared on rotation or revocation" do
    %{host: host} = Marshall.ComputeFixtures.host_fixture()
    {token, _} = Token.issue()
    params = %{name: "host-key", role: :gateway, host_id: host.id, token: token}
    {:ok, service} = Ingress.configure_service(params, actor: SystemActor.compute())
    key = host_key()

    publish = fn credential, value ->
      Ingress.publish_host_key(%{token: credential, public_key: value},
        actor: SystemActor.compute()
      )
    end

    assert {:ok, registered} = publish.(token, key)

    assert registered == %{
             service_id: service.id,
             host_id: host.id,
             generation: 1,
             public_key: key
           }

    assert {:ok, ^registered} = publish.(token, key)
    assert {:error, _} = publish.(token, host_key())
    assert {:error, _} = publish.(token, key <> " comment")

    assert {:error, _} =
             Ingress.publish_host_key(%{token: token, public_key: key},
               actor: Marshall.ComputeFixtures.user()
             )

    assert [stored] = Ledger.read!(Service, id: service.id)
    assert stored.ssh_host_key == key
    assert [_created, _published] = Ledger.read!(Service.Version, version_source_id: service.id)

    {fresh, _} = Token.issue()

    assert {:ok, %{generation: 2}} =
             Ingress.configure_service(%{params | token: fresh}, actor: SystemActor.compute())

    assert [%{ssh_host_key: nil}] = Ledger.read!(Service, id: service.id)
    assert {:error, _} = publish.(token, key)
    assert {:ok, %{generation: 2}} = publish.(fresh, host_key())
    assert {:ok, _} = Ingress.disable_service(%{id: service.id}, actor: SystemActor.compute())
    assert [%{ssh_host_key: nil}] = Ledger.read!(Service, id: service.id)
    assert {:error, _} = publish.(fresh, key)
  end

  test "DNS service identities cannot publish gateway host keys" do
    {token, _} = Token.issue()

    {:ok, service} =
      Ingress.configure_service(%{name: "dns-host-key", role: :dns, token: token},
        actor: SystemActor.compute()
      )

    assert {:error, _} =
             Ingress.publish_host_key(%{token: token, public_key: host_key()},
               actor: SystemActor.compute()
             )

    assert [%{ssh_host_key: nil}] = Ledger.read!(Service, id: service.id)
  end

  defp host_key do
    {public, _} = :crypto.generate_key(:eddsa, :ed25519)
    "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, public::binary>>)
  end

  test "operator address changes rotate gateway bindings and audit atomically" do
    %{host: host} = Marshall.ComputeFixtures.host_fixture()
    {token, _} = Token.issue()
    addresses = ["192.0.2.10", "192.0.2.9"]

    params = %{
      name: "addresses",
      role: :gateway,
      host_id: host.id,
      token: token,
      addresses: addresses
    }

    assert {:ok, service} = Ingress.configure_service(params, actor: SystemActor.compute())
    assert [%{addresses: stored}] = Ledger.read!(Service, id: service.id)
    assert stored == Enum.sort(addresses)

    assert {:ok, _} =
             Ingress.publish_host_key(%{token: token, public_key: host_key()},
               actor: SystemActor.compute()
             )

    assert {:ok, %{generation: 1}} =
             Ingress.configure_service(%{params | addresses: Enum.reverse(addresses)},
               actor: SystemActor.compute()
             )

    assert [%{ssh_host_key: key}] = Ledger.read!(Service, id: service.id)
    assert is_binary(key)

    assert {:ok, %{generation: 2}} =
             Ingress.configure_service(%{params | addresses: ["192.0.2.10"]},
               actor: SystemActor.compute()
             )

    assert [%{addresses: ["192.0.2.10"], ssh_host_key: nil}] =
             Ledger.read!(Service, id: service.id)

    versions = Ledger.read!(Service.Version, version_source_id: service.id)
    assert length(versions) == 3
    assert Enum.any?(versions, &(Map.get(&1.changes, "addresses") == ["192.0.2.10"]))

    assert {:ok, _} = Ingress.disable_service(%{id: service.id}, actor: SystemActor.compute())
    assert {:error, _} = Ingress.configure_service(params, actor: SystemActor.compute())
  end

  test "addresses reject hostnames, noncanonical forms, duplicates and DNS role assignment" do
    %{host: host} = Marshall.ComputeFixtures.host_fixture()
    {token, _} = Token.issue()
    params = %{name: "bad-address", role: :gateway, host_id: host.id, token: token}

    for values <- [
          ["host.example"],
          ["127.1"],
          ["192.000.2.9"],
          ["2001:DB8::9"],
          ["2001:db8::9"],
          ["2001:db8:0:0:0:0:0:9"],
          ["fe80::1%eth0"],
          ["192.0.2.9", "192.0.2.9"],
          Enum.map(1..9, &"192.0.2.#{&1}")
        ] do
      assert {:error, _} =
               Ingress.configure_service(Map.put(params, :addresses, values),
                 actor: SystemActor.compute()
               )
    end

    assert {:error, _} =
             Ingress.configure_service(
               %{name: "dns-address", role: :dns, token: token, addresses: ["192.0.2.9"]},
               actor: SystemActor.compute()
             )

    assert [] = Ledger.read!(Service)
  end

  @tag :hegel_case_sandbox
  property "arbitrary public-key input cannot replace a registered identity", test_cases: 100 do
    Marshall.DataCase.isolate_property_case()
    %{host: host} = Marshall.ComputeFixtures.host_fixture()
    {token, _} = Token.issue()
    name = "immutable-property-" <> Ash.UUID.generate()

    {:ok, service} =
      Ingress.configure_service(
        %{name: name, role: :gateway, host_id: host.id, token: token},
        actor: SystemActor.compute()
      )

    key = host_key()

    {:ok, expected} =
      Ingress.publish_host_key(%{token: token, public_key: key}, actor: SystemActor.compute())

    candidate =
      draw("candidate", one_of([binary(max_length: 200), constant(key), constant(host_key())]))

    result =
      Ingress.publish_host_key(%{token: token, public_key: candidate},
        actor: SystemActor.compute()
      )

    if candidate == key,
      do: assert(result == {:ok, expected}),
      else: assert(match?({:error, _}, result))

    assert [%{ssh_host_key: ^key}] = Ledger.read!(Service, id: service.id)
  end

  @tag :hegel_case_sandbox
  property "address histories advance identity exactly when the address set changes",
    test_cases: 100 do
    Marshall.DataCase.isolate_property_case()
    %{host: host} = Marshall.ComputeFixtures.host_fixture()

    history =
      draw(
        "history",
        list_of(map(list_of(integer(1..12), max_length: 8), &Enum.uniq/1),
          min_length: 1,
          max_length: 10
        )
      )

    {token, _} = Token.issue()
    params = %{name: Ash.UUID.generate(), role: :gateway, host_id: host.id, token: token}
    assert {:ok, _} = Ingress.configure_service(params, actor: SystemActor.compute())

    Enum.reduce(history, {[], 1}, fn octets, {previous, generation} ->
      addresses = Enum.map(octets, &"192.0.2.#{&1}")
      expected = generation + if(Enum.sort(addresses) == previous, do: 0, else: 1)

      assert {:ok, service} =
               Ingress.configure_service(Map.put(params, :addresses, addresses),
                 actor: SystemActor.compute()
               )

      assert service.generation == expected
      assert [%{addresses: stored}] = Ledger.read!(Service, id: service.id)
      assert stored == Enum.sort(addresses)
      {stored, expected}
    end)
  end

  @tag :hegel_case_sandbox
  property "rotation and revocation histories reject every replaced credential",
    test_cases: 100 do
    Marshall.DataCase.isolate_property_case()

    actions =
      draw(
        "actions",
        list_of(member_of([:rotate, :disable, :repeat]), min_length: 1, max_length: 12)
      )

    {token, _} = Token.issue()
    name = "dns-" <> Ash.UUID.generate()
    params = %{name: name, role: :dns, token: token}
    assert {:ok, service} = Ingress.configure_service(params, actor: SystemActor.compute())

    Enum.reduce(actions, %{token: token, generation: 1, enabled: true, retired: []}, fn action,
                                                                                        model ->
      next =
        case action do
          :rotate ->
            {fresh, _} = Token.issue()

            assert {:ok, value} =
                     Ingress.configure_service(%{params | token: fresh},
                       actor: SystemActor.compute()
                     )

            assert value.generation == model.generation + 1

            %{
              model
              | token: fresh,
                generation: value.generation,
                enabled: true,
                retired: [model.token | model.retired]
            }

          :disable ->
            assert {:ok, value} =
                     Ingress.disable_service(%{id: service.id}, actor: SystemActor.compute())

            assert value.generation == model.generation + if(model.enabled, do: 1, else: 0)
            %{model | enabled: false, generation: value.generation}

          :repeat ->
            result =
              Ingress.configure_service(%{params | token: model.token},
                actor: SystemActor.compute()
              )

            if model.enabled,
              do: assert(match?({:ok, _}, result)),
              else: assert(match?({:error, _}, result))

            model
        end

      current = Ingress.service_identity(%{token: next.token}, actor: SystemActor.compute())

      if next.enabled,
        do: assert(match?({:ok, _}, current)),
        else: assert(match?({:error, _}, current))

      for retired <- next.retired do
        assert {:error, _} =
                 Ingress.service_identity(%{token: retired}, actor: SystemActor.compute())
      end

      next
    end)
  end
end
