defmodule Lilly.Lifecycle.TransferLifecycleTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Lilly.Lifecycle.{Import, Journal, SnapshotSet}

  # ADR-0155: one stopped full copy means one source snapshot and one receive
  # stream per transfer; the baseline/incremental states no longer exist.
  test "snapshot sets and imports expose only the single-stream states" do
    assert Enum.sort(AshStateMachine.Info.state_machine_all_states(SnapshotSet)) ==
             Enum.sort([:creating, :ready, :retiring, :retired])

    assert Enum.sort(AshStateMachine.Info.state_machine_all_states(Import)) ==
             Enum.sort([:receiving, :received, :retiring, :retired])

    assert Enum.sort(AshStateMachine.Info.state_machine_initial_states!(SnapshotSet)) ==
             [:creating, :retiring]

    assert Enum.sort(AshStateMachine.Info.state_machine_initial_states!(Import)) ==
             [:receiving, :retiring]
  end

  test "persisted payloads map to states without stream kinds or baseline slots" do
    slot = fn state ->
      %{"state" => state, "nonce" => String.duplicate("a", 32), "guid" => nil}
    end

    assert {:ok, :creating} =
             Journal.state(SnapshotSet, %{
               "phase" => "active",
               "snapshots" => %{"lilly-b" => slot.("creating")}
             })

    assert {:ok, :ready} =
             Journal.state(SnapshotSet, %{
               "phase" => "active",
               "snapshots" => %{"lilly-b" => slot.("ready")}
             })

    assert {:ok, :retired} =
             Journal.state(SnapshotSet, %{"phase" => "retired", "snapshots" => %{}})

    for snapshots <- [
          %{"lilly-a" => slot.("ready")},
          %{"lilly-a" => slot.("ready"), "lilly-b" => slot.("creating")},
          %{}
        ] do
      assert {:error, _} =
               Journal.state(SnapshotSet, %{"phase" => "active", "snapshots" => snapshots})
    end

    for state <- ["receiving", "received"] do
      assert {:ok, atom} = Journal.state(Import, %{"phase" => "active", "stream_state" => state})
      assert Atom.to_string(atom) == state
    end

    assert {:ok, :retiring} = Journal.state(Import, %{"phase" => "retiring"})
  end

  property "single-stream progressions only move forward or retire" do
    check all(
            path <-
              list_of(member_of([:receiving, :received, :retiring, :retired]), max_length: 6)
          ) do
      transitions = AshStateMachine.Info.state_machine_transitions(Import)

      allowed? = fn from, to ->
        Enum.any?(transitions, fn t ->
          (t.from == [:*] or from in List.wrap(t.from)) and to in List.wrap(t.to)
        end)
      end

      for [from, to] <- Enum.chunk_every(path, 2, 1, :discard), from != to do
        assert allowed?.(from, to) ==
                 {from, to} in [
                   {:receiving, :received},
                   {:receiving, :retiring},
                   {:received, :retiring},
                   {:retiring, :retired}
                 ]
      end
    end
  end
end
