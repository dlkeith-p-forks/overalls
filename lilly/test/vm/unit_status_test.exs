defmodule Lilly.VM.UnitStatusTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Lilly.VM.Unit

  @id "11111111-1111-4111-8111-111111111111"
  @own "/lilly.slice/lilly-vm-" <> @id <> ".service"
  @states [
    "active",
    "inactive",
    "failed",
    "activating",
    "deactivating",
    "reloading",
    "refreshing",
    "maintenance",
    nil
  ]

  # @cc [owner:ghuntley,label:verification;recovery] unit-status-inconclusive-is-retryable
  # Running requires active in this placement's cgroup with processes; stopped
  # requires inactive/failed with an empty cgroup. Transitional states and an
  # unreadable cgroup are inconclusive (retryable), never a definite unknown;
  # only a contradiction is unit_state_unknown.
  property "classification matches the model for every observation" do
    check all(
            state <- member_of(@states),
            group <- member_of([@own, "/lilly.slice/lilly-vm-other.service", "", nil]),
            populated <- member_of([true, false, :unknown])
          ) do
      expected =
        cond do
          state == "active" and group == @own and populated == true ->
            {:ok, :running}

          state in ["inactive", "failed"] and populated == false ->
            {:ok, :stopped}

          state in ["activating", "deactivating", "reloading", "refreshing"] ->
            {:error, :unit_state_unavailable}

          populated == :unknown ->
            {:error, :unit_state_unavailable}

          true ->
            {:error, :unit_state_unknown}
        end

      assert Unit.classify(state, group, populated, @id) == expected
    end
  end
end
