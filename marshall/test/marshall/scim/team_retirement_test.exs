Code.require_file("team_fixture.exs", __DIR__)

defmodule Marshall.Scim.TeamRetirementTest do
  @moduledoc "Enabling SCIM retires native teams and their machines through Oban."
  use Marshall.DataCase, async: false
  import Marshall.ComputeFixtures

  alias Marshall.Access.Grant
  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.Scim.TeamFixture, as: Fixture
  alias Marshall.Scim.TeamRetirementWorker
  alias Marshall.Teams
  alias Marshall.Teams.{Coordinator, Team, TeamMember, Transfer}

  setup do
    _host = host_fixture()
    owner = user()
    member = user()
    viewer = user()

    {:ok, team} =
      Teams.create_team(%{name: Fixture.team_name(), idempotency_key: "native"}, actor: owner)

    {:ok, _} = set_member(team, member, :member, owner)
    {:ok, vm} = Marshall.Compute.provision(request(%{team_id: team.id}), actor: owner)

    grant =
      Ledger.create!(Grant, :grant, %{
        vm_id: vm.id,
        user_id: viewer.id,
        role: :viewer,
        granted_by_id: owner.id
      })

    {:ok, transfer} = Coordinator.offer(team.id, to_string(member.email), owner)

    %{owner: owner, member: member, team: team, vm: vm, grant: grant, transfer: transfer}
  end

  test "enabling SCIM marks native teams retiring and schedules their retirement", c do
    _token = Fixture.enable!()

    [team] = Ledger.read!(Team, id: c.team.id)
    assert team.management_mode == :retiring
    assert %DateTime{} = deadline = team.scim_retirement_deadline
    assert DateTime.diff(deadline, DateTime.utc_now(), :second) > 6 * 24 * 60 * 60

    assert [job] = Oban.Testing.all_enqueued(repo: Marshall.Repo, worker: TeamRetirementWorker)
    assert job.args == %{"team_id" => c.team.id}
    assert DateTime.compare(job.scheduled_at, DateTime.add(DateTime.utc_now(), 6 * 86_400)) == :gt

    # Re-enabling is idempotent: no second deadline or job.
    Fixture.disable!()
    _token = Fixture.enable!()
    assert [%{scim_retirement_deadline: ^deadline}] = Ledger.read!(Team, id: c.team.id)
    assert [_] = Oban.Testing.all_enqueued(repo: Marshall.Repo, worker: TeamRetirementWorker)

    # Before the deadline the worker only waits; members keep read access.
    assert {:snooze, seconds} = perform(c.team.id)
    assert seconds > 0
    assert [%{desired_state: desired}] = Ledger.read!(VirtualMachine, id: c.vm.id)
    refute desired == :deleted
    assert {:ok, [%{id: team_id}]} = Teams.list_teams(%{}, actor: c.member)
    assert team_id == c.team.id
  end

  test "after the grace period a machine-free team is revoked and archived, even if SCIM is disabled",
       c do
    {:ok, bare} =
      Teams.create_team(%{name: Fixture.team_name(), idempotency_key: "bare"}, actor: c.owner)

    {:ok, _} = set_member(bare, c.member, :member, c.owner)
    {:ok, transfer} = Coordinator.offer(bare.id, to_string(c.member.email), c.owner)

    _token = Fixture.enable!()
    [bare] = Ledger.read!(Team, id: bare.id)
    expire!(bare)

    # SCIM may be disabled mid-retirement; retirement of retiring teams continues.
    Fixture.disable!()

    assert :ok = perform(bare.id)
    assert Ledger.read!(Team, id: bare.id) == []
    assert [%{archived_at: %DateTime{}}] = Ledger.history!(Team, id: bare.id)
    assert Ledger.read!(TeamMember, team_id: bare.id) == []
    assert Ledger.read!(Transfer, team_id: bare.id) == []
    assert [%{state: :cancelled}] = Ledger.history!(Transfer, id: transfer.id)
    refute Enum.any?(elem(Teams.list_teams(%{}, actor: c.member), 1), &(&1.id == bare.id))

    # Duplicate delivery after archival is a no-op.
    assert :ok = perform(bare.id)
  end

  # Requires Marshall.Compute.Lifecycle.delete_for_team to run under an audit
  # actor with an identifier (it currently passes SystemActor to
  # Ledger.transaction/2 and records requested_by_id from it).
  test "after the grace period the worker deletes team machines, then revokes and archives", c do
    _token = Fixture.enable!()
    [team] = Ledger.read!(Team, id: c.team.id)
    expire!(team)

    # Machines are deleted first; the team waits for them.
    assert {:snooze, _} = perform(c.team.id)
    assert [%{desired_state: :deleted}] = Ledger.read!(VirtualMachine, id: c.vm.id)
    assert [_] = Ledger.read!(Team, id: c.team.id)
    assert {:snooze, _} = perform(c.team.id)

    [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)
    :ok = Ledger.archive!(vm, :archive)

    assert :ok = perform(c.team.id)
    assert Ledger.read!(Team, id: c.team.id) == []
    assert Ledger.read!(TeamMember, team_id: c.team.id) == []
    assert [%{state: :cancelled}] = Ledger.history!(Transfer, id: c.transfer.id)
    assert Ledger.read!(Grant, id: c.grant.id) == []
    assert {:ok, []} = Teams.list_teams(%{}, actor: c.member)
  end

  test "retiring teams refuse every native mutation and new team resources", c do
    _token = Fixture.enable!()
    outsider = user()

    assert {:error, _} = set_member(c.team, outsider, :member, c.owner)
    assert {:error, _} = set_member(c.team, c.member, :admin, c.owner)
    assert {:error, _} = set_member(c.team, c.member, :removed, c.owner)
    assert {:error, :scim_managed} = Coordinator.cancel(c.transfer.id, c.owner)
    assert {:error, :scim_managed} = Coordinator.accept(c.transfer.id, c.member)
    assert {:error, :scim_managed} = Coordinator.decline(c.transfer.id, c.member)

    assert {:error, _} =
             Teams.create_team(%{name: Fixture.team_name(), idempotency_key: "late"},
               actor: c.owner
             )

    assert {:error, _} =
             Marshall.Compute.provision(request(%{team_id: c.team.id}), actor: c.owner)

    assert Fixture.memberships(c.team.id) ==
             Enum.sort([{c.owner.id, :owner}, {c.member.id, :member}])

    assert [%{state: :pending}] = Ledger.read!(Transfer, id: c.transfer.id)
  end

  test "a team that is no longer retiring and an unknown team complete without writes", c do
    assert :ok = perform(c.team.id)
    assert [%{management_mode: :native}] = Ledger.read!(Team, id: c.team.id)
    assert :ok = perform(Ash.UUID.generate())
    assert {:cancel, _} = perform("not-a-uuid")
  end

  @spec perform(String.t()) :: term()
  defp perform(team_id),
    do:
      Oban.Testing.perform_job(TeamRetirementWorker, %{"team_id" => team_id}, repo: Marshall.Repo)

  @spec expire!(Team.t()) :: Team.t()
  defp expire!(team) do
    Ledger.update!(team, :mark_retiring, %{
      management_mode: :retiring,
      scim_retirement_deadline: DateTime.add(DateTime.utc_now(), -1, :second)
    })
  end

  @spec set_member(Team.t(), Marshall.Accounts.User.t(), atom(), Marshall.Accounts.User.t()) ::
          {:ok, map()} | {:error, term()}
  defp set_member(team, user, role, actor) do
    Teams.set_team_member(
      %{
        team_id: team.id,
        email: to_string(user.email),
        role: role,
        idempotency_key: Ash.UUID.generate()
      },
      actor: actor
    )
  end
end
