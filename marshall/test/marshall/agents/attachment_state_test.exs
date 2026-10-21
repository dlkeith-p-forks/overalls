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

    Enum.reduce(states, :pending, fn requested, current ->
      expected = allowed?(current, requested)
      result = AttachmentState.transition(current, requested)
      assert result == if(expected, do: :ok, else: {:error, :invalid_transition})
      if expected, do: requested, else: current
    end)
  end

  test "deleted is terminal and only available content is readable by policy" do
    assert AttachmentState.transition(:deleting, :deleted) == :ok
    assert AttachmentState.transition(:deleted, :available) == {:error, :invalid_transition}
    refute :available in Map.get(AttachmentState.transitions(), :quarantined, [])
  end

  # The oracle states lifecycle obligations without reading the production table.
  @spec allowed?(AttachmentState.state(), AttachmentState.state()) :: boolean()
  defp allowed?(:pending, target), do: target in [:uploading, :failed]
  defp allowed?(:uploading, target), do: target in [:available, :quarantined, :failed]
  defp allowed?(:available, target), do: target in [:quarantined, :deleting]
  defp allowed?(:quarantined, target), do: target == :deleting
  defp allowed?(:failed, target), do: target in [:uploading, :deleting]
  defp allowed?(:deleting, target), do: target in [:deleting, :deleted]
  defp allowed?(:deleted, _target), do: false
end
