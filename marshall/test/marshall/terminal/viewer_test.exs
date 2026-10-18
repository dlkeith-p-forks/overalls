defmodule Marshall.Terminal.ViewerTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.TerminalWindow, as: Window

  test "read-only viewers cannot change PTY geometry or send input" do
    state = %{mode: :ro, channel: 1, stream: self()}

    # Control messages now include consumption receipts even for read-only
    # viewers. An incomplete/revoked login must close before any control effect.
    assert {:stop, :normal, ^state} =
             Marshall.Terminal.Viewer.handle_in(
               {~s({"op":"resize","cols":4096,"rows":512}), [opcode: :text]},
               state
             )

    assert {:ok, ^state} = Marshall.Terminal.Viewer.handle_in({"input", [opcode: :binary]}, state)
    refute_receive {:viewer_resize, _}
    refute_receive {:viewer_input, _, _}
  end

  property "refusal diagnostics classify the boundary without logging terminal contents" do
    secret = draw("secret", string(:alphanumeric, min_length: 24, max_length: 64))
    reason = draw("reason", member_of([:authority, :output_window, :input_ack]))
    bytes = "private-terminal-" <> secret

    state =
      case reason do
        :authority ->
          %{mode: :rw, channel: 1, stream: self()}

        :output_window ->
          window =
            Enum.reduce(1..Window.frame_limit(), Window.new(), fn _, window ->
              {:ok, window} = Window.take(window, 0)
              window
            end)

          %{output_window: window}

        :input_ack ->
          %{input_window: Window.new()}
      end

    logs =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :reason]], fn ->
        original = Logger.metadata()
        Logger.metadata(marshall_terminal: true)

        try do
          result =
            case reason do
              :authority ->
                Marshall.Terminal.Viewer.handle_in({bytes, [opcode: :binary]}, state)

              :output_window ->
                Marshall.Terminal.Viewer.handle_info({:terminal_output, bytes}, state)

              :input_ack ->
                Marshall.Terminal.Viewer.handle_info(
                  {:terminal_input_ack, 1, byte_size(bytes)},
                  state
                )
            end

          assert result == {:stop, :normal, state}
        after
          Logger.reset_metadata(original)
        end
      end)

    assert logs =~ "event=terminal.viewer_refused"
    assert logs =~ "reason=#{reason}"
    refute logs =~ bytes
  end

  test "an attached viewer heartbeats every five seconds without terminal data" do
    state = %{channel: 3, mode: :rw}

    assert {:push, {:text, frame}, ^state} =
             Marshall.Terminal.Viewer.handle_info(:heartbeat, state)

    assert JSON.decode!(frame) == %{"op" => "heartbeat"}
    assert_receive :heartbeat, 6_000
  end
end
