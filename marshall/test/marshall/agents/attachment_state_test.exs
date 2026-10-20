defmodule Marshall.Agents.AttachmentStateTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Marshall.Agents.AttachmentState

  property "generated lifecycle commands preserve the independent transition model" do
    states =
      draw(
        "states",
        list_of(
          member_of([
            :pending,
            :uploading,
            :available,
            :quarantined,
            :failed,
            :deleting,
            :deleted
          ]),
          min_length: 1,
          max_length: 30
        )
      )

    Enum.each(states, fn from ->
      Enum.each(states, fn to ->
        expected = to in Map.get(AttachmentState.transitions(), from, [])
        assert AttachmentState.transition(from, to) == :ok == expected
      end)
    end)
  end

  test "deleted is terminal and only available content is readable by policy" do
    assert AttachmentState.transition(:deleting, :deleted) == :ok
    assert AttachmentState.transition(:deleted, :available) == {:error, :invalid_transition}
    refute :available in Map.get(AttachmentState.transitions(), :quarantined, [])
  end
end