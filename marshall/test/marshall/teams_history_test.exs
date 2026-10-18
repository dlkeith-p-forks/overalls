defmodule Marshall.TeamsHistoryTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen

  alias Marshall.Accounts.User
  alias Marshall.Compute.Ledger
  alias Marshall.Teams
  alias Marshall.Teams.{Coordinator, TeamMember, Transfer}

  @type role :: :owner | :admin | :member | :removed
  @type command ::
          {:member, non_neg_integer(), non_neg_integer(), role()}
          | {:offer, non_neg_integer(), non_neg_integer()}
          | {:transition, :accept | :decline | :cancel, non_neg_integer(), non_neg_integer()}
  @type offer :: %{
          id: String.t(),
          from: non_neg_integer(),
          to: non_neg_integer(),
          state: :pending | :accepted | :declined | :cancelled
        }
  @type model :: %{roles: %{non_neg_integer() => role()}, transfers: [offer()]}
  @type fixture :: %{team_id: String.t(), users: {User.t(), User.t(), User.t(), User.t()}}

  # @cc [owner:ghuntley,label:verification] team-history-independent-authority
  # Generated histories MUST execute domain operations and compare persisted roles,
  # transfers and fresh reads with independent expectations after every command.
  # Rejected operations MUST preserve state, including terminal transfers. Deferred
  # owner constraints MUST be checked between operations without preventing the
  # temporary ownerless state inside an atomic transfer. SQL sandbox execution
  # does not establish independent-node races or actual outer transaction commits.
  @tag :hegel_case_sandbox
  @tag timeout: 600_000
  property "generated membership and consent histories preserve current authority",
    profile: :ci,
    test_cases: 100 do
    Marshall.DataCase.isolate_property_case()
    commands = draw("commands", list_of(command(), min_length: 15, max_length: 35))
    fixture = fixture()
    initial = %{roles: %{0 => :owner, 1 => :admin, 2 => :member}, transfers: []}

    # Every history exercises owner protection, consent, all terminal outcomes,
    # and stale owner/admin authority before exploring additional combinations.
    prefix = [
      {:member, 1, 0, :removed},
      {:offer, 0, 2},
      {:transition, :decline, 2, 0},
      {:transition, :accept, 2, 0},
      {:offer, 0, 1},
      {:transition, :cancel, 0, 1},
      {:transition, :accept, 1, 1},
      {:offer, 0, 2},
      {:transition, :accept, 2, 2},
      {:offer, 0, 1},
      {:member, 2, 0, :removed},
      {:member, 0, 3, :member}
    ]

    Enum.reduce(prefix ++ commands, initial, fn command, model ->
      next = execute(command, model, fixture)
      assert_state(next, fixture)
      next
    end)
  end

  @spec command() :: Hegel.Gen.t(command())
  defp command do
    actor = integer(0..3)

    one_of([
      tuple({constant(:member), actor, actor, member_of([:admin, :member, :removed])}),
      tuple({constant(:offer), actor, actor}),
      tuple(
        {constant(:transition), member_of([:accept, :decline, :cancel]), actor, integer(0..12)}
      )
    ])
  end

  @spec fixture() :: fixture()
  defp fixture do
    users = List.to_tuple(for _ <- 0..3, do: Marshall.ComputeFixtures.user())

    {:ok, team} =
      Teams.create_team(
        %{name: "history-" <> Ash.UUID.generate(), idempotency_key: Ash.UUID.generate()},
        actor: elem(users, 0)
      )

    fixture = %{team_id: team.id, users: users}
    assert {:ok, _} = set_member(fixture, 0, 1, :admin)
    assert {:ok, _} = set_member(fixture, 0, 2, :member)
    fixture
  end

  @spec execute(command(), model(), fixture()) :: model()
  defp execute({:member, actor, target, role}, model, fixture) do
    actor_role = model.roles[actor]
    target_role = model.roles[target]

    allowed =
      actor != target and target_role != :owner and
        (actor_role == :owner or
           (actor_role == :admin and role != :admin and target_role != :admin))

    result = set_member(fixture, actor, target, role)
    assert_result(result, allowed)

    if allowed do
      roles =
        if role == :removed,
          do: Map.delete(model.roles, target),
          else: Map.put(model.roles, target, role)

      %{model | roles: roles}
    else
      model
    end
  end

  defp execute({:offer, actor, target}, model, fixture) do
    allowed =
      model.roles[actor] == :owner and actor != target and
        Map.has_key?(model.roles, target) and
        not Enum.any?(model.transfers, &(&1.state == :pending))

    result =
      Coordinator.offer(
        fixture.team_id,
        to_string(user(fixture, target).email),
        user(fixture, actor)
      )

    assert_result(result, allowed)

    case result do
      {:ok, transfer} ->
        offer = %{id: transfer.id, from: actor, to: target, state: :pending}
        %{model | transfers: model.transfers ++ [offer]}

      {:error, _} ->
        model
    end
  end

  defp execute({:transition, action, actor, index}, model, fixture) do
    offer = Enum.at(model.transfers, rem(index, length(model.transfers)))

    allowed =
      offer.state == :pending and model.roles[offer.from] == :owner and
        if action == :cancel,
          do: actor == offer.from,
          else: actor == offer.to and Map.has_key?(model.roles, offer.to)

    result = apply(Coordinator, action, [offer.id, user(fixture, actor)])
    assert_result(result, allowed)

    if allowed do
      state = %{accept: :accepted, decline: :declined, cancel: :cancelled}[action]

      transfers =
        Enum.map(model.transfers, &if(&1.id == offer.id, do: %{&1 | state: state}, else: &1))

      roles =
        if action == :accept,
          do: model.roles |> Map.put(offer.from, :admin) |> Map.put(offer.to, :owner),
          else: model.roles

      %{model | roles: roles, transfers: transfers}
    else
      model
    end
  end

  @spec assert_result({:ok, term()} | {:error, term()}, boolean()) :: :ok
  defp assert_result(result, allowed) do
    assert match?({:ok, _}, result) == allowed, inspect(result)
    :ok
  end

  @spec assert_state(model(), fixture()) :: :ok
  defp assert_state(model, fixture) do
    members = Ledger.read!(TeamMember, team_id: fixture.team_id)
    assert Enum.count(members, &(&1.role == :owner)) == 1
    expected = Map.new(model.roles, fn {index, role} -> {user(fixture, index).id, role} end)
    assert Map.new(members, &{&1.user_id, &1.role}) == expected

    actual_transfers = Ledger.read!(Transfer, team_id: fixture.team_id)

    assert Map.new(actual_transfers, &{&1.id, &1.state}) ==
             Map.new(model.transfers, &{&1.id, &1.state})

    for index <- 0..3 do
      result = Teams.list_team_members(%{team_id: fixture.team_id}, actor: user(fixture, index))
      assert_result(result, Map.has_key?(model.roles, index))
    end

    Ecto.Adapters.SQL.query!(Marshall.Repo, "SET CONSTRAINTS ALL IMMEDIATE", [])
    Ecto.Adapters.SQL.query!(Marshall.Repo, "SET CONSTRAINTS ALL DEFERRED", [])
    :ok
  end

  @spec user(fixture(), non_neg_integer()) :: User.t()
  defp user(fixture, index), do: elem(fixture.users, index)

  @spec set_member(fixture(), non_neg_integer(), non_neg_integer(), role()) ::
          {:ok, map()} | {:error, term()}
  defp set_member(fixture, actor, target, role) do
    Teams.set_team_member(
      %{
        team_id: fixture.team_id,
        email: to_string(user(fixture, target).email),
        role: role,
        idempotency_key: Ash.UUID.generate()
      },
      actor: user(fixture, actor)
    )
  end
end
