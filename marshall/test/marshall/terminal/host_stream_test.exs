defmodule Marshall.Terminal.HostStreamTest do
  use Marshall.DataCase, async: false
  use ExUnitProperties

  alias OverallsProtocol.Terminal, as: Codec
  alias Marshall.Terminal.{HostStream, Relay}

  @session_id "9c83b4a1-1f7a-4bd2-9c4a-64c69fd3ba2e"
  @vm_id "0dd0e1a2-6bd6-4a45-9db2-5de49a7e8b3c"
  @placement_id "79a553ca-0cf8-4aef-a62e-5a86e871e817"

  if System.get_env("ANTITHESIS_HARNESS") == "1" do
    test "a private arm replays one authenticated DATA frame and receipts only after Lilly ACK" do
      root = Path.join(System.tmp_dir!(), "terminal-replay-#{System.unique_integer([:positive])}")
      File.mkdir_p!(Path.join(root, "claimed"))
      File.mkdir_p!(Path.join(root, "receipts"))
      System.put_env("OVERALLS_ANTITHESIS_TERMINAL_REPLAY_ROOT", root)

      on_exit(fn ->
        System.delete_env("OVERALLS_ANTITHESIS_TERMINAL_REPLAY_ROOT")
        File.rm_rf!(root)
      end)

      state = accepted_state()
      {channel, state} = attach(state, self(), 7)
      terminal_session_id = Ash.UUID.generate()
      state = put_in(state, [:channels, channel, :terminal_session_id], terminal_session_id)
      entry = state.channels[channel]
      request_id = Ash.UUID.generate()

      arm = %{
        "version" => 1,
        "request_id" => request_id,
        "host_id" => state.host_id,
        "connection_epoch" => state.epoch,
        "connection_session_id" => state.session_id,
        "terminal_session_id" => terminal_session_id,
        "vm_id" => entry.vm_id,
        "placement_id" => entry.placement_id,
        "execution_epoch" => entry.execution_epoch,
        "guest_session_id" => entry.guest_session_id,
        "channel" => channel
      }

      bytes = "private-marker"
      encoded = Codec.encode_data_frame(channel, 1, bytes)

      File.write!(
        Path.join(root, "active.json"),
        JSON.encode!(%{arm | "connection_epoch" => state.epoch + 1})
      )

      assert {^encoded, nil} =
               OverallsAntithesis.Marshall.TerminalReplay.maybe_duplicate(
                 encoded,
                 state,
                 entry,
                 channel,
                 1
               )

      assert File.exists?(Path.join(root, "active.json"))
      File.write!(Path.join(root, "active.json"), JSON.encode!(arm))

      assert {:reply, :ok, {:binary, wire}, state} =
               HostStream.handle_info({:viewer_input, channel, bytes}, state)

      assert wire == encoded <> encoded
      refute File.exists?(Path.join([root, "receipts", request_id <> ".json"]))

      ack =
        Codec.encode_control_frame(%{
          type: :input_ack,
          channel: channel,
          frames: 1,
          bytes: byte_size(bytes)
        })

      assert {:ok, _state} = HostStream.handle_in({ack, [opcode: :binary]}, state)
      assert_receive {:terminal_input_ack, 1, _}

      receipt =
        root
        |> Path.join("receipts")
        |> Path.join(request_id <> ".json")
        |> File.read!()
        |> JSON.decode!()

      assert receipt == %{
               "version" => 1,
               "request_id" => request_id,
               "state" => "acknowledged",
               "channel" => channel,
               "sequence" => 1,
               "acknowledged_frames" => 1
             }
    end
  end

  test "expiry after the caller cancels its alias cleans pending state without a late reply" do
    {:ok, state} = HostStream.init({Ash.UUID.generate(), @session_id, 4})
    state = %{state | hello: true}
    reply_alias = :erlang.alias()

    request = %{
      caller: self(),
      ref: make_ref(),
      reply_to: reply_alias,
      message: %{type: :listing, vm_id: @vm_id, placement_id: @placement_id, execution_epoch: 4}
    }

    assert {:reply, :ok, _, pending} = HostStream.handle_info({:relay_control, request}, state)
    key = {:listing, @vm_id}
    expiry = pending.pending[key].expiry
    :erlang.unalias(reply_alias)
    assert {:ok, expired} = HostStream.handle_info({:expire_request, key, expiry}, pending)
    assert expired.pending == %{}
    refute_receive {:relay_reply, _, _}, 0
  end

  test "create accepts the relay request shape without attaching an invisible viewer" do
    {:ok, state} = HostStream.init({Ash.UUID.generate(), @session_id, 4})
    state = %{state | hello: true}
    ref = make_ref()
    request_id = Ash.UUID.generate()

    request = %{
      caller: self(),
      ref: ref,
      message: %{
        type: :create,
        request_id: request_id,
        vm_id: @vm_id,
        placement_id: @placement_id,
        execution_epoch: 1,
        mode: :rw,
        user: "root",
        term: "xterm-256color",
        cols: 80,
        rows: 24
      }
    }

    assert {:reply, :ok, {:binary, frame}, state} =
             HostStream.handle_info({:relay_control, request}, state)

    assert {:ok, %{message: %{channel: channel}}} = Codec.decode_frame(frame)
    duplicate_ref = make_ref()

    assert {:ok, ^state} =
             HostStream.handle_info({:relay_control, %{request | ref: duplicate_ref}}, state)

    assert_receive {:relay_reply, ^duplicate_ref, {:error, :stream_busy}}

    response = %{
      type: :created,
      request_id: request_id,
      ok: true,
      channel: channel,
      guest_session_id: 1,
      reason: nil
    }

    assert {:ok, state} =
             HostStream.handle_in(
               {Codec.encode_control_frame(response), [opcode: :binary]},
               state
             )

    assert_receive {:relay_reply, ^ref, {:ok, ^response}}
    assert state.channels == %{}
    assert state.viewers == %{}
  end

  test "unanswered requests expire without expiring a newer request with the same key" do
    {:ok, state} = HostStream.init({Ash.UUID.generate(), @session_id, 4})
    state = %{state | hello: true}
    reference = make_ref()

    request = %{
      caller: self(),
      ref: reference,
      message: %{
        type: :listing,
        vm_id: @vm_id,
        placement_id: @placement_id,
        execution_epoch: 1
      }
    }

    assert {:reply, :ok, _, pending} = HostStream.handle_info({:relay_control, request}, state)
    key = {:listing, @vm_id}
    expiry = pending.pending[key].expiry
    assert {:ok, ^pending} = HostStream.handle_info({:expire_request, key, make_ref()}, pending)
    assert {:ok, expired} = HostStream.handle_info({:expire_request, key, expiry}, pending)
    assert expired.pending == %{}
    assert_receive {:relay_reply, ^reference, {:error, :timeout}}
  end

  test "only a matching hello registers the stream" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    host_id = fixture.host.id
    session_id = fixture.connection.session_id
    epoch = fixture.connection.epoch
    assert {:ok, state} = HostStream.init({host_id, session_id, epoch})
    assert {:error, :stream_unavailable} = Relay.stream_for(host_id)

    invalid = hello(host_id, session_id, epoch + 1)
    assert {:stop, :normal, rejected} = HostStream.handle_in({invalid, [opcode: :binary]}, state)
    assert rejected.hello == :rejected
    assert {:error, :stream_unavailable} = Relay.stream_for(host_id)

    assert {:ok, state} = HostStream.init({host_id, session_id, epoch})
    valid = hello(host_id, session_id, epoch)

    assert {:reply, :ok, {:binary, [_response]}, accepted} =
             HostStream.handle_in({valid, [opcode: :binary]}, state)

    assert accepted.hello
    assert {:ok, pid} = Relay.stream_for(host_id)
    assert pid == self()
    assert {:ok, :ok} = Marshall.Compute.Credentials.revoke(host_id)
    assert {:stop, :normal, _} = HostStream.handle_info(:renew_location, accepted)
  end

  test "malformed and non-hello first frames close the stream" do
    host_id = Ash.UUID.generate()
    assert {:ok, state} = HostStream.init({host_id, @session_id, 4})

    assert {:stop, :normal, malformed} =
             HostStream.handle_in(
               {<<0::32, 255::8, 0::64, 0::16>>, [opcode: :binary]},
               state
             )

    assert malformed.hello == :rejected

    non_hello = Codec.encode_data_frame(1, 1, "not-a-hello")

    assert {:stop, :normal, rejected} =
             HostStream.handle_in({non_hello, [opcode: :binary]}, state)

    assert rejected.hello == :rejected

    assert {:stop, :normal, text_rejected} =
             HostStream.handle_in({"hello", [opcode: :text]}, state)

    assert text_rejected.hello == :rejected
    assert {:error, :stream_unavailable} = Relay.stream_for(host_id)
  end

  test "coalesced output frames preserve order and drop duplicate sequences" do
    state = accepted_state()

    request = %{
      ref: make_ref(),
      caller: self(),
      message: %{
        type: :attach,
        cols: 80,
        rows: 24,
        vm_id: @vm_id,
        placement_id: @placement_id,
        execution_epoch: 4,
        guest_session_id: 11,
        mode: :rw,
        cursor: 0
      }
    }

    assert {:reply, :ok, {:binary, attach_frame}, state} =
             HostStream.handle_info({:viewer_attach, request}, state)

    assert {:ok, %{message: %{channel: channel}}} = Codec.decode_frame(attach_frame)

    attached =
      Codec.encode_control_frame(%{
        type: :attached,
        replay_bytes: 0,
        channel: channel,
        ok: true,
        guest_session_id: 11,
        from: 0,
        reason: nil
      })

    output = Codec.encode_data_frame(channel, 1, "one")
    duplicate = Codec.encode_data_frame(channel, 1, "duplicate")
    next = Codec.encode_data_frame(channel, 2, "two")

    assert {:ok, _state} =
             HostStream.handle_in(
               {attached <> output <> duplicate <> next, [opcode: :binary]},
               state
             )

    assert_receive {:terminal_attached, %{channel: ^channel}}
    assert_receive {:terminal_output, "one"}
    assert_receive {:terminal_output, "two"}
    refute_receive {:terminal_output, "duplicate"}
  end

  property "a future output sequence closes its channel while a replay is ignored" do
    state = accepted_state()

    check all(gap <- integer(3..64), max_runs: 12) do
      {channel, state} = attach(state, self(), 11)

      first = Codec.encode_data_frame(channel, 1, "one")
      duplicate = Codec.encode_data_frame(channel, 1, "duplicate")
      future = Codec.encode_data_frame(channel, gap, "future")

      assert {:reply, :ok, {:binary, close_frames}, state} =
               HostStream.handle_in({first <> duplicate <> future, [opcode: :binary]}, state)

      assert_receive {:terminal_output, "one"}
      refute_receive {:terminal_output, "duplicate"}
      refute_receive {:terminal_output, "future"}
      assert_receive {:terminal_closed, %{reason: :fenced}}
      refute Map.has_key?(state.channels, channel)
      refute Map.has_key?(state.viewers, channel)

      assert Enum.any?(List.wrap(close_frames), fn frame ->
               match?(
                 {:ok, %{message: %{type: :channel_close, channel: ^channel}}},
                 Codec.decode_frame(frame)
               )
             end)
    end
  end

  test "a slow viewer closes only its channel without delaying another viewer" do
    state = accepted_state()
    slow = spawn(fn -> receive do: (:release -> :ok) end)
    on_exit(fn -> Process.exit(slow, :kill) end)

    Enum.each(1..64, fn value -> send(slow, {:queued, value}) end)

    {slow_channel, state} = attach(state, slow, 11)
    {fast_channel, state} = attach(state, self(), 12)

    slow_output = Codec.encode_data_frame(slow_channel, 1, "slow")
    fast_output = Codec.encode_data_frame(fast_channel, 1, "fast")

    assert {:reply, :ok, {:binary, close_frames}, state} =
             HostStream.handle_in({slow_output <> fast_output, [opcode: :binary]}, state)

    assert_receive {:terminal_output, "fast"}
    refute_receive {:terminal_output, "slow"}
    refute Map.has_key?(state.channels, slow_channel)
    assert Map.has_key?(state.channels, fast_channel)

    assert Enum.any?(List.wrap(close_frames), fn frame ->
             match?(
               {:ok, %{message: %{type: :channel_close, channel: ^slow_channel}}},
               Codec.decode_frame(frame)
             )
           end)
  end

  # @cc [owner:ghuntley,label:verification;reliability] generated-viewer-mailbox-isolation
  # A slow viewer at the 64-message bound MUST be shed once, without forwarding
  # beyond the bound or preventing any other active channel from advancing.
  property "generated mailbox pressure sheds only the stalled viewer" do
    check all(prefill <- integer(60..64), fast_count <- integer(1..3), max_runs: 8) do
      state = accepted_state()
      owner = self()

      slow =
        start_supervised!(
          {Task,
           fn ->
             receive do
               {:terminal_attached, _} -> send(owner, :slow_attached)
             end

             receive do
               :release -> :ok
             end
           end},
          id: make_ref()
        )

      {slow_channel, state} = attach(state, slow, 11)
      assert_receive :slow_attached

      {fast_channels, state} =
        Enum.map_reduce(1..fast_count, state, fn index, current ->
          attach(current, self(), index + 11)
        end)

      for channel <- fast_channels do
        assert_receive {:terminal_attached, %{channel: ^channel}}
      end

      Enum.each(1..prefill, fn index -> send(slow, {:queued, index}) end)
      assert {:message_queue_len, ^prefill} = Process.info(slow, :message_queue_len)

      first =
        Enum.map(fast_channels, fn channel ->
          Codec.encode_data_frame(channel, 1, "fast-#{channel}-one")
        end)

      stalled =
        Enum.map(1..6, fn sequence ->
          Codec.encode_data_frame(slow_channel, sequence, "slow")
        end)

      second =
        Enum.map(fast_channels, fn channel ->
          Codec.encode_data_frame(channel, 2, "fast-#{channel}-two")
        end)

      assert {:reply, :ok, {:binary, close_frames}, state} =
               HostStream.handle_in(
                 {IO.iodata_to_binary([first, stalled, second]), [opcode: :binary]},
                 state
               )

      refute Map.has_key?(state.channels, slow_channel)
      refute Map.has_key?(state.viewers, slow_channel)

      assert Enum.count(List.wrap(close_frames), fn frame ->
               match?(
                 {:ok, %{message: %{type: :channel_close, channel: ^slow_channel}}},
                 Codec.decode_frame(frame)
               )
             end) == 1

      assert {:messages, slow_messages} = Process.info(slow, :messages)
      assert Enum.count(slow_messages, &match?({:terminal_output, _}, &1)) == 64 - prefill
      assert Enum.count(slow_messages, &(&1 == :terminal_slow_viewer)) == 1

      for channel <- fast_channels do
        first_output = "fast-#{channel}-one"
        second_output = "fast-#{channel}-two"
        assert_receive {:terminal_output, ^first_output}
        assert_receive {:terminal_output, ^second_output}
        assert state.channels[channel].output_sequence == 2
        assert Map.has_key?(state.viewers, channel)
      end
    end
  end

  @spec accepted_state() :: map()
  defp accepted_state do
    fixture = Marshall.TerminalFixtures.terminal_fixture()
    host_id = fixture.host.id
    session_id = fixture.connection.session_id
    epoch = fixture.connection.epoch
    assert {:ok, state} = HostStream.init({host_id, session_id, epoch})

    assert {:reply, :ok, {:binary, [_response]}, state} =
             HostStream.handle_in({hello(host_id, session_id, epoch), [opcode: :binary]}, state)

    state
  end

  defp attach(state, caller, guest_session_id) do
    request = %{
      ref: make_ref(),
      caller: caller,
      message: %{
        type: :attach,
        cols: 80,
        rows: 24,
        vm_id: @vm_id,
        placement_id: @placement_id,
        execution_epoch: 4,
        guest_session_id: guest_session_id,
        mode: :ro,
        cursor: 0
      }
    }

    assert {:reply, :ok, {:binary, attach_frame}, state} =
             HostStream.handle_info({:viewer_attach, request}, state)

    assert {:ok, %{message: %{channel: channel}}} = Codec.decode_frame(attach_frame)

    attached =
      Codec.encode_control_frame(%{
        type: :attached,
        replay_bytes: 0,
        channel: channel,
        ok: true,
        guest_session_id: guest_session_id,
        from: 0,
        reason: nil
      })

    assert {:ok, state} = HostStream.handle_in({attached, [opcode: :binary]}, state)
    {channel, state}
  end

  defp hello(host_id, session_id, epoch) do
    Codec.encode_control_frame(%{
      type: :hello,
      host_id: host_id,
      session_id: session_id,
      epoch: epoch
    })
  end
end
