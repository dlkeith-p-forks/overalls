defmodule Marshall.Terminal.PeerLivenessTest do
  use ExUnit.Case, async: true

  alias Marshall.Terminal.{PeerSocket, Remote}

  # @cc [owner:ghuntley,label:verification;recovery] peer-hop-liveness-deadlines
  # Fifteen seconds of silence MUST end either side of a peer hop; any frame,
  # including a ping, MUST renew the peer socket's deadline.
  test "a silent peer hop ends on both sides; any frame renews the socket's deadline" do
    now = System.monotonic_time(:millisecond)
    stale = %{last_seen: now - 16_000, phase: :attached}

    assert {:stop, :normal, _} = PeerSocket.handle_info(:liveness, stale)
    assert {:ok, renewed} = PeerSocket.handle_control({"", [opcode: :ping]}, stale)
    assert renewed.last_seen >= now
    assert {:ok, _} = PeerSocket.handle_info(:liveness, renewed)

    assert {:stop, :normal, _} =
             Remote.handle_info(:heartbeat, %{last_seen: now - 16_000, socket: nil})
  end
end
