defmodule Marshall.TeamsCreationTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen

  alias Marshall.Accounts.{AdminEvent, User}
  alias Marshall.Compute.Ledger
  alias Marshall.Teams
  alias Marshall.Teams.{Coordinator, Team, TeamMember}

  @type creation :: %{team: Team.t(), creator_id: String.t()}
  @type model :: %{String.t() => creation()}
  @type snapshot :: %{
          team: [Team.t()],
          members: [TeamMember.t()],
          receipts: [AdminEvent.t()],
          versions: [Ash.Resource.Record.t()],
          member_versions: [Ash.Resource.Record.t()]
        }

  # @cc [owner:ghuntley,label:verification;security] team-create-history-oracle
  # Generated creation histories MUST check every reply against the actor/name
  # model and compare persisted memberships, audit receipts and versions after
  # retries and refusals. Archived names MUST acquire a fresh identity and owner.
  property "creation histories isolate actors, names, retries and archived generations",
    test_cases: 25 do
    check all(
            operations <-
              list_of(tuple({integer(0..2), integer(0..1), integer(0..2)}),
                min_length: 1,
                max_length: 15
              ),
            test_cases: 25
          ) do
      actors = for _ <- 0..2, do: Marshall.ComputeFixtures.user()
      prefix = "create-" <> binary_part(Ash.UUID.generate(), 0, 8)
      names = [prefix <> "-a", prefix <> "-b"]

      # Every generated history includes both a retry and a foreign collision.
      model =
        Enum.reduce([{0, 0, 0}, {0, 0, 0}, {1, 0, 0} | operations], %{}, fn
          {actor_index, name_index, key}, model ->
            actor = Enum.fetch!(actors, actor_index)
            name = Enum.fetch!(names, name_index)
            create_step(model, actor, name, Integer.to_string(key))
        end)

      name = hd(names)
      %{team: previous} = Map.fetch!(model, name)
      assert {:ok, :ok} = Ledger.transaction(fn -> Ledger.archive!(previous, :archive) end)
      model = Map.delete(model, name)
      actor = Enum.fetch!(actors, 2)
      model = create_step(model, actor, name, "0")
      refute model[name].team.id == previous.id
      assert length(Ledger.history!(Team, name: name)) == 2
      create_step(model, actor, name, "different-retry-key")
    end
  end

  property "transferred names cannot create false success for either owner identity",
    test_cases: 15 do
    check all(
            role <- member_of([:admin, :member]),
            remove_creator? <- boolean(),
            key <- string(:alphanumeric, min_length: 1, max_length: 16),
            test_cases: 15
          ) do
      creator = Marshall.ComputeFixtures.user()
      target = Marshall.ComputeFixtures.user()
      name = "transfer-create-" <> binary_part(Ash.UUID.generate(), 0, 8)
      assert {:ok, team} = create(creator, name, key)
      assert {:ok, _} = set_member(team.id, target, role, creator)
      assert {:ok, transfer} = Coordinator.offer(team.id, to_string(target.email), creator)
      assert {:ok, _} = Coordinator.accept(transfer.id, target)

      if remove_creator?, do: assert({:ok, _} = set_member(team.id, creator, :removed, target))
      before = snapshot(team.id)

      for actor <- [creator, target] do
        assert {:error, _} = create(actor, name, key)
        assert snapshot(team.id) == before
      end

      assert Coordinator.roles(team.id).owner == target.id
    end
  end

  @spec create_step(model(), User.t(), String.t(), String.t()) :: model()
  defp create_step(model, actor, name, key) do
    case Map.fetch(model, name) do
      :error ->
        assert {:ok, team} = create(actor, name, key)
        assert team.archived_at == nil
        assert [%{user_id: user_id, role: :owner}] = Ledger.read!(TeamMember, team_id: team.id)
        assert user_id == actor.id
        assert team.created_by_id == actor.id
        receipts = Ledger.read!(AdminEvent, target_id: team.id)
        assert Enum.sort(Enum.map(receipts, & &1.kind)) == [:team_create, :team_membership_change]
        assert Enum.all?(receipts, &(&1.actor_id == actor.id))
        Map.put(model, name, %{team: team, creator_id: actor.id})

      {:ok, %{team: team, creator_id: creator_id}} ->
        before = snapshot(team.id)

        if creator_id == actor.id do
          assert {:ok, retried} = create(actor, name, key)
          assert retried.id == team.id
        else
          assert {:error, _} = create(actor, name, key)
          refute Coordinator.member?(team.id, actor.id)
          assert {:error, _} = Teams.list_team_members(%{team_id: team.id}, actor: actor)
        end

        assert snapshot(team.id) == before
        assert [%{id: id}] = Ledger.read!(Team, name: name)
        assert id == team.id
        model
    end
  end

  @spec snapshot(String.t()) :: snapshot()
  defp snapshot(team_id) do
    members = Ledger.history!(TeamMember, team_id: team_id)

    %{
      team: Ledger.history!(Team, id: team_id),
      members: members,
      receipts: Ledger.read!(AdminEvent, target_id: team_id),
      versions: Ledger.read!(Team.Version, version_source_id: team_id),
      member_versions:
        Enum.flat_map(members, &Ledger.read!(TeamMember.Version, version_source_id: &1.id))
    }
  end

  @spec create(User.t(), String.t(), String.t()) :: {:ok, Team.t()} | {:error, term()}
  defp create(actor, name, key),
    do: Teams.create_team(%{name: name, idempotency_key: key}, actor: actor)

  @spec set_member(String.t(), User.t(), :admin | :member | :removed, User.t()) ::
          {:ok, map()} | {:error, term()}
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
end
