defmodule Marshall.Scim.LifecyclePropertyTest do
  @moduledoc "State-model properties for duplicate and out-of-order SCIM lifecycle events."
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  defp apply_event(:delete, %{finalized: true} = state), do: state
  defp apply_event(:delete, state), do: Map.put(state, :retiring, true)
  defp apply_event(:inactive, %{finalized: true} = state), do: state
  defp apply_event(:inactive, state), do: Map.put(state, :retiring, true)
  defp apply_event(:active, %{finalized: true} = state), do: state
  defp apply_event(:active, state), do: Map.put(state, :retiring, false)
  defp apply_event(:deadline, %{retiring: true} = state), do: %{state | finalized: true}
  defp apply_event(:deadline, state), do: state

  property "SCIM lifecycle events converge and finalized identities never resurrect",
    test_cases: 200 do
    check all(
            events <- list_of(member_of([:delete, :inactive, :active, :deadline]), min_length: 1)
          ) do
      initial = %{retiring: false, finalized: false}
      final = Enum.reduce(events, initial, &apply_event/2)

      if final.finalized do
        assert final.retiring
        assert apply_event(:active, final) == final
      end

      # Duplicate delivery repeats each event in place. Replaying the whole
      # history would let an earlier deadline act on a later delete.
      duplicated = Enum.flat_map(events, &[&1, &1])
      assert Enum.reduce(duplicated, initial, &apply_event/2) == final
    end
  end

  property "machine pause precedes deletion for every retirement sequence", test_cases: 200 do
    check all(
            events <- list_of(member_of([:delete, :inactive, :active, :deadline]), min_length: 1)
          ) do
      {_, paused?, deleted?} =
        Enum.reduce(events, {false, false, false}, fn event, {retiring?, paused?, deleted?} ->
          case event do
            event when event in [:delete, :inactive] -> {true, true, deleted?}
            :deadline when retiring? and paused? -> {retiring?, paused?, true}
            :active -> {false, paused?, deleted?}
            _ -> {retiring?, paused?, deleted?}
          end
        end)

      assert not deleted? or paused?
    end
  end
end
