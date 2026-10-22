defmodule Marshall.ThreadsMachineAccessTest do
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures

  alias Marshall.Access.Authorization
  alias Marshall.Accounts.{GuestAccount, User}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.Threads.{Grant, Thread}

  @type role :: :viewer | :operator | :manager

  setup do
    fixture = Marshall.TerminalFixtures.terminal_fixture(%{profile: :standard})

    %{
      owner: fixture.owner,
      vm: fixture.vm,
      member: user(),
      thread: bound_thread(fixture.owner, fixture.vm)
    }
  end

  test "thread roles drive fresh machine permissions and bounded discovery without copied grants",
       c do
    for role <- [:viewer, :operator, :manager] do
      grant = grant(c.thread, c.member, role)

      assert {:ok, view} = Marshall.Compute.get_vm(%{vm_id: c.vm.id}, actor: c.member)
      assert view.permissions.read
      assert view.permissions.write == role in [:operator, :manager]
      assert view.permissions.manage == (role == :manager)

      assert {:ok, %{items: [listed], next_cursor: nil}} =
               Marshall.Compute.list_vms(%{limit: 1}, actor: c.member)

      assert listed.id == c.vm.id
      assert Ledger.read!(Marshall.Access.Grant, vm_id: c.vm.id) == []

      :ok = Ledger.archive!(grant, :revoke)
      assert {:error, _} = Marshall.Compute.get_vm(%{vm_id: c.vm.id}, actor: c.member)
      assert {:ok, %{items: []}} = Marshall.Compute.list_vms(%{}, actor: c.member)
    end
  end

  test "thread grants and independent machine grants remain additive through revocation", c do
    thread_grant = grant(c.thread, c.member, :manager)

    direct_grant =
      Ledger.create!(Marshall.Access.Grant, :grant, %{
        vm_id: c.vm.id,
        user_id: c.member.id,
        role: :viewer,
        granted_by_id: c.owner.id
      })

    assert Authorization.allowed?(c.vm, c.member, "manage")
    :ok = Ledger.archive!(thread_grant, :revoke)
    assert Authorization.allowed?(c.vm, c.member, "read")
    refute Authorization.allowed?(c.vm, c.member, "write")

    grant(c.thread, c.member, :operator)
    :ok = Ledger.archive!(direct_grant, :revoke)
    assert Authorization.allowed?(c.vm, c.member, "write")
    refute Authorization.allowed?(c.vm, c.member, "manage")
  end

  test "a retained grant follows only the current machine binding after archival and reopen", c do
    grant = grant(c.thread, c.member, :operator)

    archived =
      Marshall.ThreadStateFixture.archived!(c.thread)

    refute Authorization.allowed?(c.vm, c.member, "read")
    assert {:ok, %{items: []}} = Marshall.Compute.list_vms(%{}, actor: c.member)

    assert {:ok, replacement} = Marshall.Compute.provision(request(), actor: c.owner)

    reopened =
      Marshall.ThreadStateFixture.reopened!(archived, Ash.UUID.generate())

    Marshall.ThreadStateFixture.provisioning!(reopened, %{machine_id: replacement.id})

    refute Authorization.allowed?(c.vm, c.member, "read")
    assert Authorization.allowed?(replacement, c.member, "write")
    assert [%{id: grant_id}] = Ledger.read!(Grant, thread_id: c.thread.id)
    assert grant_id == grant.id
    assert Ledger.read!(Marshall.Access.Grant, user_id: c.member.id) == []

    assert {:ok, %{items: [listed]}} = Marshall.Compute.list_vms(%{}, actor: c.member)
    assert listed.id == replacement.id
  end

  test "revoking a thread grant preserves independent team machine access", c do
    assert {:ok, team} =
             Marshall.Teams.create_team(
               %{name: "shared-thread-team", idempotency_key: Ash.UUID.generate()},
               actor: c.owner
             )

    assert {:ok, _} =
             Marshall.Teams.set_team_member(
               %{
                 team_id: team.id,
                 email: to_string(c.member.email),
                 role: :member,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: c.owner
             )

    assert {:ok, vm} =
             Marshall.Compute.provision(request(%{team_id: team.id}), actor: c.owner)

    thread = bound_thread(c.owner, vm)
    grant = grant(thread, c.member, :manager)
    assert Authorization.allowed?(vm, c.member, "manage")
    :ok = Ledger.archive!(grant, :revoke)
    refute Authorization.allowed?(vm, c.member, "manage")
    assert Authorization.allowed?(vm, c.member, "write")
    assert {:ok, %{items: [listed]}} = Marshall.Compute.list_vms(%{}, actor: c.member)
    assert listed.id == vm.id
  end

  test "foreign thread ownership and Customer profiles cannot confer machine access", c do
    foreign_thread = bound_thread(user(), c.vm)
    grant(foreign_thread, c.member, :manager)
    refute Authorization.allowed?(c.vm, c.member, "read")
    assert {:ok, %{items: []}} = Marshall.Compute.list_vms(%{}, actor: c.member)

    assert {:ok, customer} =
             Marshall.Compute.provision(request(%{profile: :customer}), actor: c.owner)

    customer_thread = bound_thread(c.owner, customer)
    grant(customer_thread, c.member, :manager)
    refute Authorization.allowed?(customer, c.member, "read")
    assert {:ok, %{items: []}} = Marshall.Compute.list_vms(%{}, actor: c.member)
  end

  test "thread roster candidates require write permission and disappear after revocation", c do
    grant = grant(c.thread, c.member, :operator)
    viewer = user()
    grant(c.thread, viewer, :viewer)
    {:ok, credential} = Marshall.Inference.Credentials.rotate(c.vm.host_id, 3600)
    token = credential.id <> "." <> credential.secret
    binding = Marshall.TerminalFixtures.roster_binding(c.vm)

    assert {:ok, %{accounts: accounts}} = Marshall.SSH.GuestAccess.roster(token, binding)
    assert length(accounts) == 2
    assert [%{username: username}] = Ledger.read!(GuestAccount, user_id: c.member.id)
    assert Enum.any?(accounts, &(&1.username == username))
    assert Ledger.read!(GuestAccount, user_id: viewer.id) == []

    :ok = Ledger.archive!(grant, :revoke)
    assert {:ok, %{accounts: remaining}} = Marshall.SSH.GuestAccess.roster(token, binding)
    assert length(remaining) == 1
    refute Enum.any?(remaining, &(&1.username == username))
  end

  test "retired owners deny thread-derived machine authority immediately", c do
    grant(c.thread, c.member, :operator)
    assert Authorization.allowed?(c.vm, c.member, "write")
    Ledger.update!(c.owner, :security_state, %{deleted_at: DateTime.utc_now()})
    refute Authorization.allowed?(c.vm, c.member, "read")
    assert {:ok, %{items: []}} = Marshall.Compute.list_vms(%{}, actor: c.member)
  end

  test "deleted-user cleanup archives canonical thread grants and leaves shared machines intact",
       c do
    grant = grant(c.thread, c.member, :manager)
    admin = Marshall.PasskeyFixture.verified_session(Marshall.PasskeyFixture.user(true))

    assert {:ok, deletion} =
             User
             |> Ash.ActionInput.for_action(
               :delete_user,
               %{user_id: c.member.id, confirmation: to_string(c.member.email)},
               actor: admin
             )
             |> Ash.run_action()

    assert {:ok, %{complete: true}} =
             Marshall.Accounts.DeleteUserMachines.run(
               %Ash.ActionInput{arguments: %{primary_key: %{"id" => deletion.id}}},
               [],
               %{actor: SystemActor.compute()}
             )

    assert Ledger.read!(Grant, user_id: c.member.id) == []
    assert [%{archived_at: %DateTime{}}] = Ledger.history!(Grant, id: grant.id)
    assert [%{desired_state: :running}] = Ledger.read!(VirtualMachine, id: c.vm.id)
  end

  @spec bound_thread(User.t(), VirtualMachine.t()) :: Thread.t()
  defp bound_thread(owner, vm) do
    key = Ash.UUID.generate()

    Thread
    |> Ledger.create!(:open, %{
      creator_id: owner.id,
      objective: "Shared machine work",
      mode: :medium,
      machine_spec: request(),
      idempotency_key: key,
      machine_key: key
    })
    |> Marshall.ThreadStateFixture.ready!(%{machine_id: vm.id})
  end

  @spec grant(Thread.t(), User.t(), role()) :: Grant.t()
  defp grant(thread, member, role) do
    Ledger.create!(Grant, :grant, %{
      thread_id: thread.id,
      user_id: member.id,
      role: role,
      granted_by_id: thread.creator_id
    })
  end
end
