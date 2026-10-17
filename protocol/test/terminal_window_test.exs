defmodule OverallsProtocol.TerminalWindowTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.TerminalWindow, as: Window

  property "cumulative consumption replenishes exactly once and preserves both bounds" do
    check all(sizes <- list_of(integer(0..65_535), min_length: 1, max_length: 200)) do
      Enum.reduce(sizes, Window.new(), fn bytes, window ->
        window =
          case Window.take(window, bytes) do
            {:ok, next} ->
              next

            {:error, :exhausted} ->
              {:ok, drained} = Window.acknowledge(window, window.sent_frames, window.sent_bytes)
              {:ok, next} = Window.take(drained, bytes)
              next
          end

        assert window.sent_bytes - window.acknowledged_bytes <= Window.byte_limit()
        assert length(window.pending) <= Window.frame_limit()

        assert {:ok, ^window} =
                 Window.acknowledge(window, window.acknowledged_frames, window.acknowledged_bytes)

        assert {:error, :invalid_receipt} =
                 Window.acknowledge(window, window.sent_frames + 1, window.sent_bytes)

        window
      end)
    end
  end

  test "tiny frames cannot bypass the frame budget and fabricated byte counts grant nothing" do
    window =
      Enum.reduce(1..16, Window.new(), fn _, window ->
        {:ok, next} = Window.take(window, 1)
        next
      end)

    assert {:error, :exhausted} = Window.take(window, 1)
    assert {:error, :invalid_receipt} = Window.acknowledge(window, 8, 9)
    assert {:ok, drained} = Window.acknowledge(window, 8, 8)
    assert {:ok, ^drained} = Window.acknowledge(drained, 8, 8)
    assert {:ok, ^drained} = Window.acknowledge(drained, 4, 4)
    assert length(drained.pending) == 8
  end
end
