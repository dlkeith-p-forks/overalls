defmodule Lilly.Control.ReadinessTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Control.Runtime

  # @cc [owner:ghuntley,label:verification;recovery] generated-readiness-fresh-authority
  # A delivered report is fresh through exactly fifteen seconds. Readiness MUST
  # require every durable placement's current actor authority, and a missing,
  # stale or foreign actor MUST refuse even when the report is fresh.
  @tag :hegel
  test "generated report ages and actor rosters require every current authority" do
    Hegel.check(
      fn ->
        age_ms = draw("age_ms", member_of([-1, 0, 1, 14999, 15000, 15001, 30000]))

        actor_cases =
          draw(
            "actor_cases",
            list_of(
              member_of([:current, :missing, :old_epoch, :old_generation, :foreign_placement]),
              min_length: 1,
              max_length: 4
            )
          )

        now = DateTime.utc_now()

        {durable, actors} =
          actor_cases
          |> Enum.with_index(1)
          |> Enum.reduce({%{}, %{}}, fn {actor_case, index}, {durable, actors} ->
            placement_id = "placement-#{index}"
            command = %{placement_id: placement_id, execution_epoch: 4, generation: 7}

            actor =
              case actor_case do
                :current -> %{reconciled: {placement_id, 4, 7}}
                :missing -> nil
                :old_epoch -> %{reconciled: {placement_id, 3, 7}}
                :old_generation -> %{reconciled: {placement_id, 4, 6}}
                :foreign_placement -> %{reconciled: {"foreign", 4, 7}}
              end

            actors = if actor, do: Map.put(actors, placement_id, actor), else: actors
            {Map.put(durable, placement_id, command), actors}
          end)

        state = %{
          phase: :connected,
          terminal_ready: true,
          last_error: nil,
          sample_error: nil,
          delivered_report_at: DateTime.add(now, -age_ms, :millisecond),
          durable: durable,
          actors: actors
        }

        expected = age_ms >= 0 and age_ms <= 15_000 and Enum.all?(actor_cases, &(&1 == :current))
        assert Runtime.readiness(state, now) == expected
      end,
      test_cases: 100
    )
  end

  test "fresh local collection is insufficient without delivery and reconciliation" do
    now = DateTime.utc_now()

    state = %{
      phase: :connected,
      terminal_ready: true,
      last_error: nil,
      sample_error: nil,
      delivered_report_at: now,
      durable: %{"vm" => %{placement_id: "placement", execution_epoch: 2, generation: 2}},
      actors: %{"vm" => %{reconciled: {"placement", 2, 2}}}
    }

    assert Runtime.readiness(state, now)
    refute Runtime.readiness(%{state | delivered_report_at: nil}, now)
    refute Runtime.readiness(state, DateTime.add(now, 15_001, :millisecond))
    refute Runtime.readiness(state, DateTime.add(now, -1, :millisecond))
    refute Runtime.readiness(%{state | actors: %{}}, now)

    refute Runtime.readiness(
             %{state | actors: %{"vm" => %{reconciled: {"placement", 2, 1}}}},
             now
           )

    refute Runtime.readiness(
             %{state | actors: %{"vm" => %{reconciled: {"placement", 1, 2}}}},
             now
           )

    refute Runtime.readiness(%{state | actors: %{"vm" => %{reconciled: {"former", 2, 2}}}}, now)
    refute Runtime.readiness(%{state | phase: :fenced}, now)
    refute Runtime.readiness(%{state | terminal_ready: false}, now)
    refute Runtime.readiness(%{state | sample_error: :collection_failed}, now)
    refute Runtime.readiness(%{state | last_error: :transport_error}, now)
  end

  test "terminal lookup uses the sole runnable placement and rejects ambiguity" do
    command = %{vm_id: "vm", placement_id: "new", execution_epoch: 2, kind: :start}

    state = %{
      terminal: self(),
      phase: :connected,
      durable: %{"new" => command, "old" => %{command | placement_id: "old", kind: :delete}},
      actors: %{"new" => %{pid: self()}}
    }

    test = self()

    assert {:reply, {:ok, ^test}, ^state} =
             Runtime.handle_call({:terminal_actor, "vm"}, {test, nil}, state)

    ambiguous = put_in(state.durable["old"].kind, :start)

    assert {:reply, {:error, :terminal_unavailable}, ^ambiguous} =
             Runtime.handle_call({:terminal_actor, "vm"}, {test, nil}, ambiguous)

    assert {:reply, {:error, :not_terminal_owner}, ^state} =
             Runtime.handle_call({:terminal_actor, "vm"}, {nil, nil}, state)

    assert {:reply, {:ok, ^test}, ^state} =
             Runtime.handle_call({:terminal_actor, "vm", "new", 2}, {test, nil}, state)

    assert {:reply, {:error, :terminal_unavailable}, ^state} =
             Runtime.handle_call({:terminal_actor, "vm", "old", 2}, {test, nil}, state)

    assert {:reply, {:error, :terminal_unavailable}, ^state} =
             Runtime.handle_call({:terminal_actor, "vm", "new", 1}, {test, nil}, state)
  end
end
