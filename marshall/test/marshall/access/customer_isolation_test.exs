defmodule Marshall.Access.CustomerIsolationTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  alias Marshall.{Access, Compute, Ingress}
  alias Marshall.Access.{Authorization, Grant}
  alias Marshall.Compute.Ledger

  setup do
    c = Marshall.TerminalFixtures.terminal_fixture(%{profile: :customer})
    Map.put(c, :member, user())
  end

  property "customer grants cannot be created or confer authority", c do
    check all(role <- member_of([:web, :viewer, :operator, :manager]), max_runs: 12) do
      assert {:error, _} =
               Access.set_access(
                 %{
                   vm_id: c.vm.id,
                   email: to_string(c.member.email),
                   role: role,
                   idempotency_key: Ash.UUID.generate()
                 },
                 actor: c.owner
               )

      assert [] = Ledger.read!(Grant, vm_id: c.vm.id)

      for action <- ["read", "write", "manage", "web"] do
        refute Authorization.allowed?(c.vm, c.member, action)
        assert Authorization.allowed?(c.vm, c.owner, action) == (action != "web")
      end
    end
  end

  test "stale manager grants cannot expose listings, terminal or lifecycle", c do
    Ledger.create!(Grant, :grant, %{
      vm_id: c.vm.id,
      user_id: c.member.id,
      granted_by_id: c.owner.id,
      role: :manager
    })

    for action <- ["read", "write", "manage", "web"],
        do: refute(Authorization.allowed?(c.vm, c.member, action))

    assert {:ok, %{items: []}} = Compute.list_vms(%{}, actor: c.member)
    assert {:error, _} = Compute.get_vm(%{vm_id: c.vm.id}, actor: c.member)

    assert {:error, :forbidden} =
             Marshall.Terminal.Authority.open_session(c.vm, c.member, "root", "xterm-256color")

    assert {:ok, _} =
             Access.set_access(
               %{
                 vm_id: c.vm.id,
                 email: to_string(c.member.email),
                 role: :revoked,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: c.owner
             )

    assert [] = Ledger.read!(Grant, vm_id: c.vm.id)
  end

  test "administrator status does not bypass Customer ownership", c do
    admin =
      Ash.Seed.seed!(Marshall.Accounts.User, %{
        email: "admin-#{Ash.UUID.generate()}@example.test",
        administrator: true
      })
      |> Marshall.PasskeyFixture.verified_session()

    for action <- ["read", "write", "manage", "web"],
        do: refute(Authorization.allowed?(c.vm, admin, action))
  end

  # @cc [owner:ghuntley,label:verification;security] customer-lifecycle-admin-refusal
  # An elevated administrator MUST be refused Customer lifecycle and reads even
  # through real domain actions, while the same elevation manages a non-Customer
  # machine; refusals MUST leave no operation rows.
  test "elevated administrator refuses Customer lifecycle but manages OSS", c do
    admin = Marshall.PasskeyFixture.user(true) |> Marshall.PasskeyFixture.verified_session()
    stranger = user()
    operations = Ledger.read!(Marshall.Compute.Operation, vm_id: c.vm.id)

    for actor <- [admin, stranger] do
      assert {:error, _} = Compute.get_vm(%{vm_id: c.vm.id}, actor: actor)

      for kind <- [:start, :stop, :delete] do
        assert {:error, _} =
                 Compute.lifecycle(
                   %{vm_id: c.vm.id, kind: kind, idempotency_key: Ash.UUID.generate()},
                   actor: actor
                 )
      end
    end

    assert Ledger.read!(Marshall.Compute.Operation, vm_id: c.vm.id) == operations

    {:ok, other} = Compute.provision(request(%{profile: :oss}), actor: c.owner)
    assert Authorization.allowed?(other, admin, "manage")

    assert {:ok, _} =
             Compute.lifecycle(
               %{vm_id: other.id, kind: :stop, idempotency_key: Ash.UUID.generate()},
               actor: admin
             )

    assert {:ok, _} =
             Compute.lifecycle(
               %{vm_id: other.id, kind: :start, idempotency_key: Ash.UUID.generate()},
               actor: admin
             )

    assert 1 ==
             length(Ledger.read!(Marshall.Compute.Operation, vm_id: other.id, kind: :stop))
  end

  property "even the owner cannot configure customer web exposure", c do
    [before] = Ledger.read!(Marshall.Ingress.Endpoint, vm_id: c.vm.id)

    check all(
            port <- integer(1..65535),
            visibility <- member_of([:public, :private]),
            max_runs: 12
          ) do
      assert {:error, _} =
               Ingress.configure_endpoint(
                 %{
                   vm_id: c.vm.id,
                   expected_revision: before.policy_revision,
                   primary_port: port,
                   visibility: visibility
                 },
                 actor: c.owner
               )

      assert [^before] = Ledger.read!(Marshall.Ingress.Endpoint, vm_id: c.vm.id)
    end
  end
end
