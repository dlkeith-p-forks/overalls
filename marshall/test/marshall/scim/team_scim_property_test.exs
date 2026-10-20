Code.require_file("team_fixture.exs", __DIR__)

defmodule Marshall.Scim.TeamScimPropertyTest do
  @moduledoc "Generated SCIM Group histories against a reference membership model."
  use MarshallWeb.ConnCase, async: false
  import Hegel
  import Hegel.Gen

  alias Marshall.Compute.Ledger
  alias Marshall.Scim.TeamFixture, as: Fixture
  alias Marshall.Teams.{ServiceOwner, Team, TeamMember}

  @slots 0..2
  @people 0..3

  @typep slot :: 0..2
  @typep person :: 0..3
  @typep operation ::
           {:create, slot(), [person()]}
           | {:add, slot(), person()}
           | {:remove, slot(), person()}
           | {:replace, slot(), [person()]}
           | {:rename, slot()}
           | {:delete, slot()}
  @typep group :: %{id: Ash.UUID.t(), name: String.t(), members: MapSet.t(person())}
  @typep model :: %{optional(slot()) => group() | {:deleted, group()}}

  # @cc [owner:ghuntley,label:verification;security] scim-group-membership-model
  # Every generated SCIM Group history (create, add, remove, replace, rename,
  # delete) MUST leave each active SCIM team with exactly the modelled members
  # plus exactly one owner, the hidden service owner; deleted groups MUST keep
  # only that owner until TeamRetirementWorker archives them.
  @tag hegel_case_sandbox: true
  test "SCIM membership converges to the model with exactly one hidden owner" do
    Hegel.check(
      fn ->
        Marshall.DataCase.isolate_property_case()
        token = Fixture.enable!()
        people = Map.new(@people, &{&1, Marshall.ComputeFixtures.user().id})
        owner = ServiceOwner.get!().id

        operations = draw("operations", list_of(operation(), min_length: 1, max_length: 12))

        model =
          Enum.reduce(operations, %{}, fn operation, model ->
            model = apply_operation(operation, model, token, people)
            check!(model, people, owner)
            model
          end)

        # Deleted groups finish retirement through the worker and archive.
        for {_slot, %{id: id}} <- deleted_ids(model) do
          assert :ok =
                   Oban.Testing.perform_job(
                     Marshall.Scim.TeamRetirementWorker,
                     %{"team_id" => id},
                     repo: Marshall.Repo
                   )

          assert Ledger.read!(Team, id: id) == []
          assert Ledger.read!(TeamMember, team_id: id) == []
        end

        check!(model, people, owner)
      end,
      test_cases: 50
    )
  end

  @spec operation() :: term()
  defp operation do
    slot = member_of(Enum.to_list(@slots))
    person = member_of(Enum.to_list(@people))
    people = uniq_list_of(person, max_length: 4)

    one_of([
      tuple({constant(:create), slot, people}),
      tuple({constant(:add), slot, person}),
      tuple({constant(:remove), slot, person}),
      tuple({constant(:replace), slot, people}),
      map(slot, &{:rename, &1}),
      map(slot, &{:delete, &1})
    ])
  end

  @spec apply_operation(operation(), model(), String.t(), %{person() => Ash.UUID.t()}) :: model()
  defp apply_operation({:create, slot, members}, model, token, people)
       when not is_map_key(model, slot) do
    name = Fixture.team_name()
    body = Fixture.group(name, Enum.map(members, &people[&1]))
    assert {201, %{"id" => id}} = Fixture.request(token, :post, "/Groups", body)
    Map.put(model, slot, %{id: id, name: name, members: MapSet.new(members)})
  end

  defp apply_operation({:add, slot, person}, model, token, people) do
    with_group(model, slot, fn group ->
      op = %{"op" => "add", "path" => "members", "value" => [%{"value" => people[person]}]}
      assert {200, _} = Fixture.request(token, :patch, "/Groups/#{group.id}", Fixture.patch([op]))
      %{group | members: MapSet.put(group.members, person)}
    end)
  end

  defp apply_operation({:remove, slot, person}, model, token, people) do
    with_group(model, slot, fn group ->
      op = %{"op" => "remove", "path" => ~s(members[value eq "#{people[person]}"])}
      assert {200, _} = Fixture.request(token, :patch, "/Groups/#{group.id}", Fixture.patch([op]))
      %{group | members: MapSet.delete(group.members, person)}
    end)
  end

  defp apply_operation({:replace, slot, members}, model, token, people) do
    with_group(model, slot, fn group ->
      body = Fixture.group(group.name, Enum.map(members, &people[&1]))
      assert {200, _} = Fixture.request(token, :put, "/Groups/#{group.id}", body)
      %{group | members: MapSet.new(members)}
    end)
  end

  defp apply_operation({:rename, slot}, model, token, _people) do
    with_group(model, slot, fn group ->
      name = Fixture.team_name()
      op = %{"op" => "replace", "path" => "displayName", "value" => name}
      assert {200, _} = Fixture.request(token, :patch, "/Groups/#{group.id}", Fixture.patch([op]))
      %{group | name: name}
    end)
  end

  defp apply_operation({:delete, slot}, model, token, _people) do
    case model do
      %{^slot => %{id: id} = group} ->
        assert {204, nil} = Fixture.request(token, :delete, "/Groups/#{id}")
        assert {404, _} = Fixture.request(token, :get, "/Groups/#{id}")
        Map.put(model, slot, {:deleted, group})

      _ ->
        model
    end
  end

  # Creating an occupied (or deleted) slot is a no-op in the model and is not sent.
  defp apply_operation(_operation, model, _token, _people), do: model

  @spec with_group(model(), slot(), (group() -> group())) :: model()
  defp with_group(model, slot, fun) do
    case model do
      %{^slot => %{id: _} = group} -> Map.put(model, slot, fun.(group))
      _ -> model
    end
  end

  @spec deleted_ids(model()) :: [{slot(), group()}]
  defp deleted_ids(model),
    do: for({slot, {:deleted, group}} <- model, do: {slot, group})

  @spec check!(model(), %{person() => Ash.UUID.t()}, Ash.UUID.t()) :: :ok
  defp check!(model, people, owner) do
    Enum.each(model, fn
      {_slot, %{id: id, name: name, members: members}} ->
        expected = Enum.sort([{owner, :owner} | Enum.map(members, &{people[&1], :member})])
        assert Fixture.memberships(id) == expected
        assert [%{name: ^name, management_mode: :scim_managed}] = Ledger.read!(Team, id: id)

      {_slot, {:deleted, %{id: id}}} ->
        case Ledger.read!(Team, id: id) do
          [%{management_mode: :retiring}] -> assert Fixture.memberships(id) == [{owner, :owner}]
          [] -> assert Fixture.memberships(id) == []
        end
    end)
  end
end
