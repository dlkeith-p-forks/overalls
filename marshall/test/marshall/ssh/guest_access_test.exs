defmodule Marshall.SSH.GuestAccessTest do
  use Marshall.DataCase, async: false
  use ExUnitProperties

  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Inference.Credentials
  alias Marshall.Ingress
  alias Marshall.SSH.GuestAccess

  setup context do
    fixture =
      Marshall.TerminalFixtures.terminal_fixture(%{
        profile: Map.get(context, :profile, :customer)
      })

    {:ok, credential} = Credentials.rotate(fixture.vm.host_id, 3600)
    ziggy_token = credential.id <> "." <> credential.secret
    {gateway_token, _} = Ingress.Token.issue()

    {:ok, _} =
      Ingress.configure_service(
        %{
          name: "ssh-guest-test",
          role: :gateway,
          host_id: fixture.vm.host_id,
          token: gateway_token
        },
        actor: SystemActor.compute()
      )

    key = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 42::256>>)
    {:ok, registered} = Marshall.SSH.add_key(%{public_key: key}, actor: fixture.owner)
    [endpoint] = Ledger.read!(Ingress.Endpoint, vm_id: fixture.vm.id)

    binding = %{
      "host_id" => fixture.vm.host_id,
      "vm_id" => fixture.vm.id,
      "placement_id" => fixture.vm.current_placement_id,
      "execution_epoch" => fixture.vm.execution_epoch
    }

    Map.merge(fixture, %{
      ziggy_token: ziggy_token,
      gateway_token: gateway_token,
      key: key,
      ssh_key: registered,
      binding: binding,
      roster_binding: Marshall.TerminalFixtures.roster_binding(fixture.vm),
      label: endpoint.label
    })
  end

  test "roster is current and key probes never create login audit rows", c do
    {:ok, roster} = GuestAccess.roster(c.ziggy_token, c.roster_binding)
    assert roster.version > 0
    assert [%{username: username, uid: uid}] = roster.accounts
    assert username == "u#{uid}"
    assert uid >= 200_000

    assert {:error, :unauthorized} =
             GuestAccess.authorize(c.ziggy_token, c.binding, c.key, username)

    assert Ledger.read!(Marshall.SSH.GuestLogin) == []

    {:ok, _session} =
      Ingress.open_ssh(
        %{service_token: c.gateway_token, public_key: c.key, label: c.label},
        actor: SystemActor.compute()
      )

    assert {:ok, %{public_key: key}} =
             GuestAccess.authorize(c.ziggy_token, c.binding, c.key, username)

    assert key == c.key
    assert Ledger.read!(Marshall.SSH.GuestLogin) == []

    assert {:ok, %{login_id: id}} =
             GuestAccess.login(c.ziggy_token, c.binding, c.key, username)

    assert [%{id: ^id, key_id: key_id}] = Ledger.read!(Marshall.SSH.GuestLogin)
    assert key_id == c.ssh_key.id

    assert {:error, :unauthorized} =
             GuestAccess.authorize(c.ziggy_token, c.binding, c.key, "other")

    {:ok, _} = Marshall.SSH.remove_key(%{id: c.ssh_key.id}, actor: c.owner)

    assert {:error, :unauthorized} =
             GuestAccess.login(c.ziggy_token, c.binding, c.key, username)

    assert length(Ledger.read!(Marshall.SSH.GuestLogin)) == 1
  end

  # @cc [owner:ghuntley,label:verification;security] guest-authorized-keys-pull-authority-test
  # The pulled key list MUST name the roster's writers with exactly their
  # unarchived registered keys, MUST drop a removed key on the next pull and
  # MUST refuse a foreign binding, without ever recording a login.
  test "authorized keys are pulled per account and follow key removal", c do
    {:ok, roster} = GuestAccess.roster(c.ziggy_token, c.roster_binding)
    [%{username: username, uid: uid}] = roster.accounts
    {:ok, keys} = GuestAccess.authorized_keys(c.ziggy_token, c.binding)
    assert keys.version > roster.version
    assert [%{username: ^username, uid: ^uid, keys: [key]}] = keys.accounts
    assert key == c.key
    assert Ledger.read!(Marshall.SSH.GuestLogin) == []

    assert {:error, :unauthorized} =
             GuestAccess.authorized_keys(c.ziggy_token, %{
               c.binding
               | "vm_id" => c.binding["host_id"]
             })

    assert {:error, :unauthorized} = GuestAccess.authorized_keys(c.ziggy_token, c.roster_binding)
    assert {:error, :unauthorized} = GuestAccess.authorized_keys("not-a-token", c.binding)

    {:ok, _} = Marshall.SSH.remove_key(%{id: c.ssh_key.id}, actor: c.owner)
    {:ok, keys} = GuestAccess.authorized_keys(c.ziggy_token, c.binding)
    assert [%{username: ^username, keys: []}] = keys.accounts
  end

  test "different physical binding and credential cannot list accounts", c do
    assert {:error, :unauthorized} =
             GuestAccess.roster(
               c.ziggy_token,
               Map.put(c.roster_binding, "host_id", Ash.UUID.generate())
             )

    assert {:error, :unauthorized} = GuestAccess.roster("invalid", c.roster_binding)
  end

  test "verified current boot can fetch its roster before the start outcome", c do
    {:ok, vm} = Marshall.Compute.provision(Marshall.ComputeFixtures.request(), actor: c.owner)
    [operation] = Ledger.read!(Marshall.Compute.Operation, vm_id: vm.id)

    binding = %{
      "host_id" => vm.host_id,
      "vm_id" => vm.id,
      "placement_id" => vm.current_placement_id,
      "execution_epoch" => vm.execution_epoch,
      "generation" => vm.generation,
      "operation_id" => operation.id
    }

    assert operation.status == :pending
    assert {:ok, %{accounts: [_]}} = GuestAccess.roster(c.ziggy_token, binding)

    assert {:error, :unauthorized} =
             GuestAccess.roster(c.ziggy_token, Map.drop(binding, ~w(generation operation_id)))

    username = Marshall.SharingSurfacesFixture.member_name(c.owner)

    assert {:error, :unauthorized} =
             GuestAccess.authorize(c.ziggy_token, binding, c.key, username)

    assert {:error, :unauthorized} = GuestAccess.login(c.ziggy_token, binding, c.key, username)

    for {field, value} <- [
          {"generation", vm.generation + 1},
          {"operation_id", Ash.UUID.generate()}
        ] do
      assert {:error, :unauthorized} =
               GuestAccess.roster(c.ziggy_token, Map.put(binding, field, value))
    end

    operation = Ledger.update!(operation, :acknowledge, %{})
    assert {:ok, %{accounts: [_]}} = GuestAccess.roster(c.ziggy_token, binding)
    Ledger.update!(operation, :cancel, %{})
    assert {:error, :unauthorized} = GuestAccess.roster(c.ziggy_token, binding)
  end

  test "completed boot roster requires the exact successful start receipt", c do
    [operation] = Ledger.read!(Marshall.Compute.Operation, vm_id: c.vm.id)
    binding = c.roster_binding
    assert binding["operation_id"] == operation.id

    assert {:ok, %{accounts: [_]}} = GuestAccess.roster(c.ziggy_token, binding)

    # The four-field physical binding is never a roster proof.
    assert {:error, :unauthorized} = GuestAccess.roster(c.ziggy_token, c.binding)

    assert {:error, :unauthorized} =
             GuestAccess.roster(
               c.ziggy_token,
               Map.put(binding, "generation", operation.generation + 1)
             )
  end

  property "any changed physical binding denies roster, key eligibility, and login", c do
    {:ok, _session} =
      Ingress.open_ssh(
        %{service_token: c.gateway_token, public_key: c.key, label: c.label},
        actor: SystemActor.compute()
      )

    username = Marshall.SharingSurfacesFixture.member_name(c.owner)

    check all(delta <- integer(1..1_000), max_runs: 12) do
      for field <- ~w(host_id vm_id placement_id execution_epoch) do
        changed =
          if field == "execution_epoch" do
            Map.update!(c.binding, field, &(&1 + delta))
          else
            Map.put(c.binding, field, Ash.UUID.generate())
          end

        boot = Map.merge(changed, Map.take(c.roster_binding, ~w(generation operation_id)))
        assert {:error, :unauthorized} = GuestAccess.roster(c.ziggy_token, boot)

        assert {:error, :unauthorized} =
                 GuestAccess.authorize(c.ziggy_token, changed, c.key, username)

        assert {:error, :unauthorized} =
                 GuestAccess.login(c.ziggy_token, changed, c.key, username)

        assert Ledger.read!(Marshall.SSH.GuestLogin) == []
      end
    end
  end

  @tag profile: :standard
  test "grant and revocation update distinct home accounts", c do
    member = Marshall.ComputeFixtures.user()
    assert {:ok, _} = Marshall.TerminalFixtures.grant(c, member, :operator)
    {:ok, roster} = GuestAccess.roster(c.ziggy_token, c.roster_binding)
    assert length(roster.accounts) == 2
    assert length(Enum.uniq_by(roster.accounts, & &1.uid)) == 2
    assert length(Enum.uniq_by(roster.accounts, & &1.username)) == 2

    assert {:ok, _} = Marshall.TerminalFixtures.grant(c, member, :revoked)
    {:ok, after_revoke} = GuestAccess.roster(c.ziggy_token, c.roster_binding)
    assert after_revoke.version > roster.version
    assert length(after_revoke.accounts) == 1

    assert hd(after_revoke.accounts).username !=
             Marshall.SharingSurfacesFixture.member_name(member)
  end
end
