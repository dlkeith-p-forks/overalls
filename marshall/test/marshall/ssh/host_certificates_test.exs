defmodule Marshall.SSH.HostCertificatesTest do
  use Marshall.DataCase, async: false
  use ExUnitProperties
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.SSH
  alias OverallsProtocol.SSHHostCertificate, as: Certificate
  @root Path.expand("../../../../nix/tests/fixtures/ssh-host-ca", __DIR__)

  setup do
    ca = @root |> Path.join("key.pub") |> File.read!() |> String.trim()

    values = [
      ssh_host_trust: %{
        "version" => 1,
        "ca" => ca,
        "management_host" => "control.example.test",
        "zone" => "apps.example.test",
        "retirement" => 2_421_446_400
      },
      ssh_host_ca_key_file: Path.join(@root, "key")
    ]

    previous =
      Enum.map(values, fn {name, value} ->
        old = Application.fetch_env(:marshall, name)
        Application.put_env(:marshall, name, value)
        {name, old}
      end)

    on_exit(fn ->
      Enum.each(previous, fn {name, old} ->
        case old do
          {:ok, value} -> Application.put_env(:marshall, name, value)
          :error -> Application.delete_env(:marshall, name)
        end
      end)
    end)

    {token, _} = SSH.Token.issue(:gateway)
    actor = SystemActor.compute()
    {:ok, gateway} = SSH.ensure_gateway(%{name: "certificate-test", token: token}, actor: actor)
    %{token: token, actor: actor, ca: ca, gateway: gateway}
  end

  property "retries converge and replaced keys cannot resurrect an earlier generation", c do
    check all(count <- integer(2..6), max_runs: 6) do
      keys =
        Enum.map(1..count, fn _ ->
          {key, _} = :crypto.generate_key(:eddsa, :ed25519)
          "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, key::binary>>)
        end)

      for key <- keys do
        request = %{role: :porsche, token: c.token, public_key: key}
        assert {:ok, response} = SSH.host_certificate(request, actor: c.actor)
        assert {:ok, ^response} = SSH.host_certificate(request, actor: c.actor)

        assert {:ok, _} =
                 Certificate.verify(
                   response.certificate,
                   c.ca,
                   key,
                   "control.example.test",
                   System.system_time(:second)
                 )

        current = Ledger.read!(SSH.HostCertificate, status: :issued)
        assert length(current) == 1
        assert hd(current).public_key == key
      end
    end
  end

  test "revoked or wrong-role credentials cannot sign", c do
    key = c.ca

    assert {:error, _} =
             SSH.host_certificate(%{role: :audi, token: c.token, public_key: key}, actor: c.actor)

    {:ok, _} = SSH.disable_gateway(%{id: c.gateway.id}, actor: c.actor)

    assert {:error, _} =
             SSH.host_certificate(%{role: :porsche, token: c.token, public_key: key},
               actor: c.actor
             )

    assert Ledger.read!(SSH.HostCertificate) == []
  end

  test "signer outages reuse a failed generation and recovery publishes it once", c do
    Application.put_env(:marshall, :ssh_host_ca_key_file, "/nonexistent/ssh-ca")

    assert {:error, _} =
             SSH.host_certificate(%{role: :porsche, token: c.token, public_key: c.ca},
               actor: c.actor
             )

    assert [%{id: id, status: :failed, certificate: nil}] = Ledger.read!(SSH.HostCertificate)
    request = %{role: :porsche, token: c.token, public_key: c.ca}
    for _ <- 1..3, do: assert({:error, _} = SSH.host_certificate(request, actor: c.actor))
    assert [%{id: ^id, status: :failed, certificate: nil}] = Ledger.read!(SSH.HostCertificate)
    Application.put_env(:marshall, :ssh_host_ca_key_file, Path.join(@root, "key"))
    assert {:ok, response} = SSH.host_certificate(request, actor: c.actor)

    assert [%{id: ^id, status: :issued, certificate: certificate}] =
             Ledger.read!(SSH.HostCertificate)

    assert certificate == response.certificate
  end

  test "guest signing binds every boot field and derives only the authoritative endpoint", c do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    {:ok, credential} = Marshall.Inference.Credentials.rotate(fixture.vm.host_id, 3600)
    token = credential.id <> "." <> credential.secret
    [operation] = Ledger.read!(Marshall.Compute.Operation, vm_id: fixture.vm.id)

    binding = %{
      "host_id" => fixture.vm.host_id,
      "vm_id" => fixture.vm.id,
      "placement_id" => fixture.vm.current_placement_id,
      "execution_epoch" => fixture.vm.execution_epoch,
      "generation" => fixture.vm.generation,
      "operation_id" => operation.id
    }

    request = %{role: :guest, token: token, public_key: c.ca, binding: binding}
    assert {:ok, issued} = SSH.host_certificate(request, actor: c.actor)
    [endpoint] = Ledger.read!(Marshall.Ingress.Endpoint, vm_id: fixture.vm.id)
    assert issued.principal == endpoint.label <> ".apps.example.test"
    assert {:ok, ^issued} = SSH.host_certificate(request, actor: c.actor)

    for field <- ~w(host_id vm_id placement_id execution_epoch generation operation_id) do
      value =
        if field in ~w(execution_epoch generation),
          do: binding[field] + 1,
          else: Ash.UUID.generate()

      assert {:error, _} =
               SSH.host_certificate(%{request | binding: Map.put(binding, field, value)},
                 actor: c.actor
               )
    end

    assert {:error, _} =
             SSH.host_certificate(
               %{request | binding: Map.put(binding, "principal", "other.example.test")},
               actor: c.actor
             )

    assert length(Ledger.read!(SSH.HostCertificate)) == 1
  end

  test "Audi must prove its published key and gets a digest-bound principal", c do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    {token, _} = Marshall.Ingress.Token.issue()

    {:ok, _} =
      Marshall.Ingress.configure_service(
        %{name: "cert-audi", role: :gateway, host_id: fixture.vm.host_id, token: token},
        actor: c.actor
      )

    request = %{role: :audi, token: token, public_key: c.ca}
    assert {:error, _} = SSH.host_certificate(request, actor: c.actor)

    assert {:ok, _} =
             Marshall.Ingress.publish_host_key(%{token: token, public_key: c.ca},
               actor: c.actor
             )

    assert {:ok, issued} = SSH.host_certificate(request, actor: c.actor)
    assert {:ok, principal} = Certificate.gateway_principal(c.ca, "control.example.test")
    assert issued.principal == principal
  end

  test "history cleanup continues bounded batches and preserves usable generations", c do
    now = System.system_time(:second)

    for _ <- 1..501 do
      Ledger.create!(SSH.HostCertificate, :record, %{
        subject: "expired:" <> Ash.UUID.generate(),
        principal: "control.example.test",
        public_key: c.ca,
        ca: c.ca,
        serial: 1,
        valid_after: now - 10 * 86_400,
        valid_before: now - 8 * 86_400
      })
    end

    assert {:ok, issued} =
             SSH.host_certificate(%{role: :porsche, token: c.token, public_key: c.ca},
               actor: c.actor
             )

    AshOban.schedule(SSH.HostCertificate, :prune)
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :maintenance)
    assert length(Ledger.read!(SSH.HostCertificate)) == 2
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :maintenance)
    assert [%{certificate: certificate, status: :issued}] = Ledger.read!(SSH.HostCertificate)
    assert certificate == issued.certificate
  end

  test "runtime trust follows the effective public hostname and rejects malformed overrides" do
    environment = %{
      "MARSHALL_SSH_HOST_TRUST" =>
        JSON.encode!(Application.fetch_env!(:marshall, :ssh_host_trust)),
      "MARSHALL_SSH_HOST_CA_KEY_FILE" => Path.join(@root, "key"),
      "PHX_HOST" => "runtime.example.test"
    }

    previous = Map.new(environment, fn {name, _} -> {name, System.get_env(name)} end)
    on_exit(fn -> Enum.each(previous, fn {name, value} -> restore_env(name, value) end) end)
    System.put_env(environment)

    config = Config.Reader.read!("config/runtime.exs", env: :test, target: :host)
    assert config[:marshall][:ssh_host_trust]["management_host"] == "runtime.example.test"
    System.put_env("PHX_HOST", "host,*")

    assert_raise RuntimeError, "Invalid SSH host trust configuration", fn ->
      Config.Reader.read!("config/runtime.exs", env: :test, target: :host)
    end
  end

  @spec restore_env(String.t(), String.t() | nil) :: :ok
  defp restore_env(name, nil), do: System.delete_env(name)
  defp restore_env(name, value), do: System.put_env(name, value)
end
