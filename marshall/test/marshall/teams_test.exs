defmodule Marshall.TeamsTest do
  use Marshall.DataCase, async: false
  alias Marshall.Compute.Ledger
  alias Marshall.Accounts.AdminEvent
  alias Marshall.Teams
  alias Marshall.Teams.{Coordinator, TeamMember, Transfer}

  defp team_name, do: "team-" <> (Ash.UUID.generate() |> binary_part(0, 8))

  defp create_team(actor),
    do:
      Teams.create_team(%{name: team_name(), idempotency_key: Ash.UUID.generate()}, actor: actor)

  test "creating a team establishes exactly one owner membership" do
    actor = Marshall.ComputeFixtures.user()
    {:ok, team} = create_team(actor)

    [membership] = Ledger.read!(TeamMember, team_id: team.id)
    assert membership.user_id == actor.id
    assert membership.role == :owner
    assert Coordinator.member?(team.id, actor.id)

    roles = Coordinator.roles(team.id)
    assert roles.owner == actor.id
    assert actor.id in roles.admins
    assert actor.id in roles.members

    assert Enum.sort(Enum.map(Ledger.read!(AdminEvent, target_id: team.id), & &1.kind)) == [
             :team_create,
             :team_membership_change
           ]

    assert [%{actor_kind: :user, actor_id: actor_id}] =
             Ledger.read!(Marshall.Teams.Team.Version, version_source_id: team.id)

    assert actor_id == actor.id
  end

  test "database rejects direct mutations that leave an active team without an owner" do
    owner = Marshall.ComputeFixtures.user()
    {:ok, team} = create_team(owner)
    [membership] = Ledger.read!(TeamMember, team_id: team.id)

    assert_owner_constraint(fn ->
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        "UPDATE team_members SET role = 'admin' WHERE id = $1::text::uuid",
        [membership.id]
      )
    end)

    assert_owner_constraint(fn ->
      Ecto.Adapters.SQL.query!(
        Marshall.Repo,
        "UPDATE team_members SET archived_at = clock_timestamp() AT TIME ZONE 'UTC' WHERE id = $1::text::uuid",
        [membership.id]
      )
    end)
  end

  test "memberships replace roles and preserve exactly one owner" do
    owner = Marshall.ComputeFixtures.user()
    admin = Marshall.ComputeFixtures.user()
    member = Marshall.ComputeFixtures.user()
    {:ok, team} = create_team(owner)

    assert {:ok, _} =
             Teams.set_team_member(
               %{
                 team_id: team.id,
                 email: to_string(admin.email),
                 role: :admin,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: owner
             )

    assert {:ok, _} =
             Teams.set_team_member(
               %{
                 team_id: team.id,
                 email: to_string(member.email),
                 role: :member,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: owner
             )

    assert {:error, _} =
             Teams.set_team_member(
               %{
                 team_id: team.id,
                 email: to_string(owner.email),
                 role: :removed,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: owner
             )

    assert {:ok, _} =
             Teams.set_team_member(
               %{
                 team_id: team.id,
                 email: to_string(member.email),
                 role: :admin,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: owner
             )

    members = Ledger.read!(TeamMember, team_id: team.id)
    assert length(members) == 3
    assert Enum.count(members, &(&1.role == :owner)) == 1

    assert_raise Ash.Error.Invalid, fn ->
      Ledger.create!(TeamMember, :record, %{
        team_id: team.id,
        user_id: admin.id,
        role: :owner,
        recorded_by_id: owner.id
      })
    end
  end

  test "membership authority: only owner or admin manage, admins only owner appoints" do
    owner = Marshall.ComputeFixtures.user()
    admin = Marshall.ComputeFixtures.user()
    member = Marshall.ComputeFixtures.user()
    outsider = Marshall.ComputeFixtures.user()
    {:ok, team} = create_team(owner)

    assert {:ok, _} =
             Teams.set_team_member(
               %{
                 team_id: team.id,
                 email: to_string(admin.email),
                 role: :admin,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: owner
             )

    assert {:ok, _} =
             Teams.set_team_member(
               %{
                 team_id: team.id,
                 email: to_string(member.email),
                 role: :member,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: owner
             )

    assert {:error, _} =
             Teams.set_team_member(
               %{
                 team_id: team.id,
                 email: to_string(outsider.email),
                 role: :member,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: member
             )

    assert {:error, _} =
             Teams.set_team_member(
               %{
                 team_id: team.id,
                 email: to_string(outsider.email),
                 role: :member,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: outsider
             )

    assert {:ok, _} =
             Teams.set_team_member(
               %{
                 team_id: team.id,
                 email: to_string(member.email),
                 role: :removed,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: admin
             )

    assert {:error, _} =
             Teams.set_team_member(
               %{
                 team_id: team.id,
                 email: to_string(outsider.email),
                 role: :admin,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: admin
             )
  end

  test "admins cannot demote or remove the current owner" do
    owner = Marshall.ComputeFixtures.user()
    admin = Marshall.ComputeFixtures.user()
    {:ok, team} = create_team(owner)
    assert {:ok, _} = set_member(team.id, admin, :admin, owner)
    receipts = Ledger.read!(AdminEvent, target_id: team.id)

    for role <- [:admin, :member, :removed] do
      assert {:error, _} = set_member(team.id, owner, role, admin)
      assert Coordinator.roles(team.id).owner == owner.id
      assert Ledger.read!(AdminEvent, target_id: team.id) == receipts
    end
  end

  test "ownership transfer walks its closed state machine and swaps atomically" do
    owner = Marshall.ComputeFixtures.user()
    target = Marshall.ComputeFixtures.user()
    {:ok, team} = create_team(owner)

    assert {:ok, _} =
             Teams.set_team_member(
               %{
                 team_id: team.id,
                 email: to_string(target.email),
                 role: :admin,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: owner
             )

    assert {:error, _} = Coordinator.offer(team.id, to_string(target.email), target)

    assert {:ok, transfer} = Coordinator.offer(team.id, to_string(target.email), owner)
    assert transfer.state == :pending

    assert {:error, _} = Coordinator.accept(transfer.id, owner)
    assert {:error, _} = Coordinator.cancel(transfer.id, target)

    assert {:ok, accepted} = Coordinator.accept(transfer.id, target)
    assert accepted.state == :accepted

    assert Enum.sort(Enum.map(Ledger.read!(AdminEvent, target_id: transfer.id), & &1.kind)) == [
             :team_transfer_accept,
             :team_transfer_offer
           ]

    assert {:error, _} = Coordinator.accept(transfer.id, target)
    assert {:error, _} = Coordinator.cancel(transfer.id, owner)

    roles = Coordinator.roles(team.id)
    assert roles.owner == target.id
    assert owner.id in roles.admins

    members = Ledger.read!(TeamMember, team_id: team.id)
    assert Enum.count(members, &(&1.role == :owner)) == 1
  end

  test "decline and cancel close pending transfers without changing ownership" do
    owner = Marshall.ComputeFixtures.user()
    target = Marshall.ComputeFixtures.user()
    {:ok, team} = create_team(owner)

    assert {:ok, _} =
             Teams.set_team_member(
               %{
                 team_id: team.id,
                 email: to_string(target.email),
                 role: :member,
                 idempotency_key: Ash.UUID.generate()
               },
               actor: owner
             )

    {:ok, transfer} = Coordinator.offer(team.id, to_string(target.email), owner)
    assert {:ok, declined} = Coordinator.decline(transfer.id, target)
    assert declined.state == :declined

    assert {:ok, second} = Coordinator.offer(team.id, to_string(target.email), owner)
    assert {:ok, cancelled} = Coordinator.cancel(second.id, owner)
    assert cancelled.state == :cancelled

    assert Coordinator.roles(team.id).owner == owner.id
    assert [] == Ledger.read!(Transfer, team_id: team.id, state: :pending)
  end

  test "team listing shows memberships and roles" do
    owner = Marshall.ComputeFixtures.user()
    {:ok, team} = create_team(owner)

    assert {:ok, [%{id: id, role: :owner}]} = Teams.list_teams(%{}, actor: owner)
    assert id == team.id
    expected_owner = owner.id

    assert {:ok, [%{user_id: ^expected_owner, role: :owner, email: _}]} =
             Teams.list_team_members(%{team_id: team.id}, actor: owner)
  end

  test "nested team events are discarded when the outer transaction rolls back" do
    owner = Marshall.ComputeFixtures.user()
    target = Marshall.ComputeFixtures.user()
    {:ok, team} = create_team(owner)

    logs =
      ExUnit.CaptureLog.capture_log([metadata: [:event]], fn ->
        assert {:error, :forced_rollback} =
                 Ledger.transaction(fn ->
                   assert {:ok, _} = set_member(team.id, target, :member, owner)
                   assert {:ok, _} = Coordinator.offer(team.id, to_string(target.email), owner)
                   Ledger.rollback(:forced_rollback)
                 end)
      end)

    refute logs =~ "event=team.membership_changed"
    refute logs =~ "event=team.transfer_changed"
    refute Coordinator.member?(team.id, target.id)
    assert [] == Ledger.read!(Transfer, team_id: team.id)
  end

  defp set_member(team_id, user, role, actor) do
    Teams.set_team_member(
      %{
        team_id: team_id,
        email: to_string(user.email),
        role: role,
        idempotency_key: Ash.UUID.generate()
      },
      actor: actor
    )
  end

  @spec assert_owner_constraint((-> term())) :: :ok
  defp assert_owner_constraint(mutation) do
    assert {:error,
            %Postgrex.Error{
              postgres: %{code: :check_violation, constraint: "teams_exactly_one_active_owner"}
            }} =
             Marshall.Repo.transaction(
               fn ->
                 mutation.()

                 case Ecto.Adapters.SQL.query(
                        Marshall.Repo,
                        "SET CONSTRAINTS ALL IMMEDIATE",
                        []
                      ) do
                   {:error, error} -> Marshall.Repo.rollback(error)
                   {:ok, _result} -> :ok
                 end
               end,
               mode: :savepoint
             )

    :ok
  end
end
