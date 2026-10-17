defmodule Marshall.Terminal.HostTakeoverHistoryTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen

  alias OverallsProtocol.Terminal, as: Codec
  alias Marshall.Terminal.{Directory, Relay}
  alias Marshall.TerminalAttachmentSocket, as: Socket
  alias Marshall.TerminalHostSocket, as: HostSocket

  @type binding :: %{session_id: String.t(), epoch: pos_integer()}

  setup do
    previous = Application.fetch_env(:marshall, :terminal_peer_url)
    Application.put_env(:marshall, :terminal_peer_url, "https://localhost:4443")

    on_exit(fn ->
      case previous do
        {:ok, value} -> Application.put_env(:marshall, :terminal_peer_url, value)
        :error -> Application.delete_env(:marshall, :terminal_peer_url)
      end
    end)

    :ok
  end

  # @cc [owner:ghuntley,label:verification] host-takeover-live-renewal-oracle
  # Generated takeovers MUST rotate real database session authority with a live
  # channel, observe the old WebSock process exit, reject its delayed hello and
  # retain a usable current successor. Explicit renewal delivery verifies the
  # renewal decision, not the five-second scheduler or per-frame database fencing.
  property "live host channels cede on renewal and replacement across session takeovers" do
    fixture = Marshall.TerminalFixtures.terminal_fixture()

    server =
      start_supervised!(
        {Bandit,
         plug: {HostSocket, %{observer: self()}}, ip: {127, 0, 0, 1}, port: 0, startup_log: false}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    check all(
            orders <- shuffle([:renew_first, :successor_first]),
            guest_ids <- list_of(member_of([1, 2, 9_223_372_036_854_775_807]), length: 2),
            max_runs: 3
          ) do
      binding = Marshall.TerminalFixtures.connect(fixture.credential.token, fixture.machine)
      incumbent = accepted(port, fixture.credential.token, fixture.host.id, binding)

      {incumbent, _binding} =
        Enum.zip(orders, guest_ids)
        |> Enum.reduce({incumbent, binding}, fn {order, guest_id}, {old, previous} ->
          channel = attach(old, fixture.vm, guest_id)
          output(old, channel, 1, "before-takeover")
          assert {:ok, old_location} = Directory.lookup(fixture.host.id)
          delayed = HostSocket.connect(port, fixture.credential.token)

          current = Marshall.TerminalFixtures.connect(fixture.credential.token, fixture.machine)
          assert current.epoch > previous.epoch

          refute Directory.current_execution?(
                   fixture.host.id,
                   previous.session_id,
                   previous.epoch
                 )

          assert Directory.current_execution?(fixture.host.id, current.session_id, current.epoch)

          successor =
            case order do
              :renew_first ->
                send(old.process, :renew_location)
                Socket.closed(old)

                assert {:error, :stream_unavailable} =
                         Relay.local_stream(fixture.host.id, old_location.nonce)

                accepted(port, fixture.credential.token, fixture.host.id, current)

              :successor_first ->
                successor = accepted(port, fixture.credential.token, fixture.host.id, current)
                Socket.closed(old)
                successor
            end

          assert {:ok, successor_pid} = Relay.stream_for(fixture.host.id)
          assert successor_pid == successor.process
          assert {:ok, new_location} = Directory.lookup(fixture.host.id)
          refute new_location.nonce == old_location.nonce
          assert {:error, _} = Directory.renew(fixture.host.id, old_location.nonce)
          assert {:ok, ^new_location} = Directory.lookup(fixture.host.id)

          assert {:error, :stream_unavailable} =
                   Relay.local_stream(fixture.host.id, old_location.nonce)

          assert :ok = HostSocket.send_binary(delayed, hello(fixture.host.id, previous))
          Socket.closed(delayed)
          assert {:ok, ^successor_pid} = Relay.stream_for(fixture.host.id)
          assert {:ok, ^new_location} = Directory.lookup(fixture.host.id)

          send(successor.process, :renew_location)
          Socket.barrier(successor)
          next_channel = attach(successor, fixture.vm, guest_id)
          output(successor, next_channel, 1, "successor-output")
          {successor, current}
        end)

      Socket.disconnect(incumbent)
      assert {:ok, location} = Directory.lookup(fixture.host.id)
      assert {:error, :stream_unavailable} = Relay.local_stream(fixture.host.id, location.nonce)
    end
  end

  @spec accepted(pos_integer(), String.t(), String.t(), binding()) :: Socket.t()
  defp accepted(port, token, host_id, binding) do
    client = HostSocket.connect(port, token)
    assert :ok = HostSocket.send_binary(client, hello(host_id, binding))
    assert {2, response} = Socket.frame(client)

    assert {:ok, %{message: %{type: :hello_response, interval_ms: 1000}}} =
             Codec.decode_frame(response)

    client
  end

  @spec hello(String.t(), binding()) :: binary()
  defp hello(host_id, binding) do
    Codec.encode_control_frame(%{
      type: :hello,
      host_id: host_id,
      session_id: binding.session_id,
      epoch: binding.epoch
    })
  end

  @spec attach(Socket.t(), Marshall.Compute.VirtualMachine.t(), pos_integer()) :: pos_integer()
  defp attach(client, vm, guest_id) do
    send(
      client.process,
      {:viewer_attach,
       %{
         caller: self(),
         ref: make_ref(),
         message: %{
           type: :attach,
           vm_id: vm.id,
           placement_id: vm.current_placement_id,
           execution_epoch: vm.execution_epoch,
           guest_session_id: guest_id,
           mode: :ro,
           cursor: 0,
           cols: 80,
           rows: 24
         }
       }}
    )

    assert {2, request} = Socket.frame(client)
    assert {:ok, %{message: %{type: :attach, channel: channel}}} = Codec.decode_frame(request)

    assert :ok =
             HostSocket.send_binary(
               client,
               Codec.encode_control_frame(%{
                 type: :attached,
                 channel: channel,
                 guest_session_id: guest_id,
                 ok: true,
                 replay_bytes: 0,
                 from: 0,
                 reason: nil
               })
             )

    assert_receive {:terminal_attached, %{channel: ^channel}}
    channel
  end

  @spec output(Socket.t(), pos_integer(), pos_integer(), binary()) :: :ok
  defp output(client, channel, sequence, bytes) do
    assert :ok = HostSocket.send_binary(client, Codec.encode_data_frame(channel, sequence, bytes))
    assert_receive {:terminal_output, ^bytes}
    :ok
  end
end
