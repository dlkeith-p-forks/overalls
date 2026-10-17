defmodule Lilly.Terminal.HeartbeatTest do
  use ExUnit.Case, async: true
  alias Lilly.Terminal.Stream

  test "a missing hello response expires without promoting readiness" do
    state = waiting_state(System.monotonic_time(:millisecond) - 5001)
    assert {:noreply, next} = Stream.handle_info(:heartbeat, state)
    assert next.phase == :disconnected
    assert_receive {:terminal_stream_ready, _, false}
    refute_receive {:terminal_stream_ready, _, true}
  end

  test "a heartbeat tick sends nothing before the hello response" do
    state = waiting_state(System.monotonic_time(:millisecond))
    # No WebSocket exists in this state: attempting a heartbeat send would fail.
    assert {:noreply, ^state} = Stream.handle_info(:heartbeat, state)
    refute_receive {:terminal_stream_ready, _, true}
  end

  @spec waiting_state(integer()) :: map()
  defp waiting_state(at) do
    %{
      phase: :authenticating,
      heartbeat_at: at,
      heartbeat_sent: 0,
      heartbeat_acked: 0,
      runtime: self(),
      client: %{host_id: "11111111-1111-4111-8111-111111111111"},
      websocket: nil,
      channels: %{},
      buffer: <<>>,
      backoff: 1000
    }
  end
end
