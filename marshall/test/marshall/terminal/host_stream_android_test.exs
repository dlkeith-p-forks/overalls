defmodule Marshall.Terminal.HostStreamAndroidTest do
  use ExUnit.Case, async: true

  alias Marshall.Terminal.HostStream
  alias OverallsProtocol.Terminal, as: Codec

  @session_id "9c83b4a1-1f7a-4bd2-9c4a-64c69fd3ba2e"
  @vm_id "0dd0e1a2-6bd6-4a45-9db2-5de49a7e8b3c"
  @placement_id "79a553ca-0cf8-4aef-a62e-5a86e871e817"

  test "a future Android output sequence closes the channel and notifies its owner" do
    {:ok, state} = HostStream.init({Ash.UUID.generate(), @session_id, 4})
    state = %{state | hello: true}

    request = %{
      caller: self(),
      ref: make_ref(),
      message: %{
        type: :android_display_open,
        vm_id: @vm_id,
        placement_id: @placement_id,
        execution_epoch: 4,
        generation: 9,
        mode: :viewer,
        ticket: "ticket",
        channel: 1
      }
    }

    assert {:reply, :ok, {:binary, open_frame}, pending} =
             HostStream.handle_info({:relay_control, request}, state)

    assert {:ok, %{message: %{channel: channel}}} = Codec.decode_frame(open_frame)

    opened = %{
      type: :android_display_opened,
      channel: channel,
      generation: 9,
      ok: true,
      reason: nil
    }

    assert {:ok, opened_state} =
             HostStream.handle_in(
               {Codec.encode_control_frame(opened), [opcode: :binary]},
               pending
             )

    assert_receive {:relay_reply, _, {:ok, ^opened}}
    gap = Codec.encode_data_frame(channel, 2, <<1>>)

    assert {:reply, :ok, {:binary, close_frame}, closed_state} =
             HostStream.handle_in({gap, [opcode: :binary]}, opened_state)

    assert {:ok, %{message: %{type: :android_display_close, channel: ^channel}}} =
             Codec.decode_frame(close_frame)

    assert_receive {:android_display_closed, ^channel, 9, :sequence_gap}
    assert closed_state.android_channels == %{}
  end
end
