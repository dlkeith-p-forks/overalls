defmodule Lilly.Terminal.Stream do
  @moduledoc "Persistent multiplexed terminal stream to Marshall over one authenticated WebSocket."
  use GenServer
  require Lilly.Events

  alias Lilly.Control.Client
  alias Lilly.Terminal.{Channel, Guest}
  alias OverallsProtocol.WebSocket.Connection
  alias OverallsProtocol.Terminal, as: Codec
  alias OverallsProtocol.TerminalWindow, as: Window

  @dial_backoff_min 1000
  @dial_backoff_max 30_000
  # Marshall's host stream accepts frames up to this size; several terminal
  # frames may share one WebSocket message.
  @frame_limit 262_158

  @enforce_keys [:client, :session, :runtime]
  defstruct [
    :client,
    :session,
    :runtime,
    :websocket,
    :phase,
    :buffer,
    :channels,
    :guests,
    :next_channel,
    :backoff,
    :opening,
    :opening_connection
  ]

  # @cc [owner:ghuntley,label:recovery] stream-reconnect-and-dedup
  # The stream MUST reconnect with bounded backoff after any transport loss,
  # send hello with the exact execution session identity before any other
  # frame, and deduplicate replayed input per channel by strictly increasing
  # sequence so a lost reply can never execute guest input twice.
  # Readiness MUST remain false until a valid hello_response authenticates the
  # stream and MUST become false before reconnect scheduling after any loss.
  @spec start_link(Client.t(), map(), pid()) :: GenServer.on_start()
  def start_link(client, session, runtime) do
    GenServer.start_link(
      __MODULE__,
      %{
        client: client,
        session: session,
        runtime: runtime,
        websocket: nil,
        opening: nil,
        opening_connection: nil,
        phase: :disconnected,
        buffer: <<>>,
        channels: %{},
        android_channels: %{},
        guests: %{},
        next_channel: 1,
        backoff: @dial_backoff_min
      }
    )
  end

  @spec ready?(GenServer.server()) :: boolean()
  def ready?(stream), do: GenServer.call(stream, :ready?)

  @impl true
  def init(state) do
    Process.flag(:trap_exit, true)
    state = Map.put_new(state, :opening_connection, nil)
    send(self(), :connect)
    Process.send_after(self(), :heartbeat, 1000)
    Process.send_after(self(), :reap_guests, 5000)

    state =
      Map.merge(state, %{
        heartbeat_sent: 0,
        heartbeat_acked: 0,
        heartbeat_at: System.monotonic_time(:millisecond)
      })

    {:ok, state}
  end

  @impl true
  def handle_call(:ready?, _from, state), do: {:reply, state.phase == :authenticated, state}

  # @cc [owner:ghuntley,label:recovery] terminal-opening-socket-custody
  # The matching worker MUST register its passive socket before handoff.
  # Worker death, failed completion and stream shutdown MUST retire that socket
  # without changing guest lifetime; stale workers MUST NOT transfer custody.
  def handle_call(
        {:opening_connection, reference, %Connection{} = connection},
        {worker, _tag},
        %{opening: {reference, worker, _monitor}, opening_connection: nil} = state
      ),
      do: {:reply, :ok, %{state | opening_connection: connection}}

  def handle_call({:opening_connection, _reference, _connection}, _from, state),
    do: {:reply, :stale, state}

  @impl true
  # @cc [owner:ghuntley,label:recovery] terminal-stream-progress-deadline
  # Both hello negotiation and established transport MUST expire after five
  # seconds without acknowledged progress. Heartbeats MUST NOT precede hello
  # acknowledgement, and stale heartbeat replies MUST NOT renew the deadline.
  def handle_info(:heartbeat, state) do
    Lilly.Terminal.Metrics.report(state.client.host_id, map_size(state.channels))
    Process.send_after(self(), :heartbeat, 1000)

    if state.phase in [:authenticating, :authenticated] do
      if System.monotonic_time(:millisecond) - state.heartbeat_at >= 5000 do
        {:noreply, disconnected(state, :transport_error)}
      else
        if state.phase == :authenticating do
          {:noreply, state}
        else
          sequence = state.heartbeat_sent + 1

          case Connection.send_frame(
                 state.websocket,
                 {:binary, Codec.encode_control_frame(%{type: :heartbeat, sequence: sequence})}
               ) do
            :ok -> {:noreply, %{state | heartbeat_sent: sequence}}
            _ -> {:noreply, disconnected(state, :transport_error)}
          end
        end
      end
    else
      {:noreply, state}
    end
  end

  # @cc [owner:ghuntley,label:recovery;protocol] terminal-stream-active-transport
  # The stream MUST open its connection outside its own process, adopt only
  # the newest attempt's socket, and then receive transport messages one at a
  # time (active once); nothing polls the socket. A hung dial never delays
  # channel output, acknowledgements or the progress deadline.
  # Worker death MUST retire its attempt and schedule recovery. Stream shutdown
  # MUST retire its opening worker without terminating any guest process.
  # Abrupt stream death MUST also retire the worker and its opening transport.
  # Socket custody MUST be registered before handoff so death before completion
  # cannot leave an untracked stream-owned transport.
  def handle_info(:connect, %{opening: nil} = state) do
    owner = self()
    reference = make_ref()
    client = state.client

    {worker, monitor} =
      :erlang.spawn_opt(
        fn -> send(owner, {:stream_opened, reference, open(client, owner, reference)}) end,
        [:link, :monitor]
      )

    {:noreply, %{state | opening: {reference, worker, monitor}}}
  end

  def handle_info(:connect, state), do: {:noreply, state}

  def handle_info(
        {:stream_opened, reference, result},
        %{opening: {reference, _worker, monitor}} = state
      ) do
    Process.demonitor(monitor, [:flush])
    state = %{state | opening: nil}

    state =
      case result do
        {:ok, _connection} -> %{state | opening_connection: nil}
        _ -> retire_opening_connection(state)
      end

    case result do
      {:ok, connection} ->
        hello =
          Codec.encode_control_frame(%{
            type: :hello,
            host_id: state.client.host_id,
            session_id: state.session.session_id,
            epoch: state.session.epoch
          })

        with :ok <- Connection.send_frame(connection, {:binary, hello}),
             :ok <- Connection.activate(connection) do
          state = %{
            state
            | websocket: connection,
              phase: :authenticating,
              heartbeat_at: System.monotonic_time(:millisecond),
              buffer: <<>>,
              backoff: @dial_backoff_min
          }

          {:noreply, transport(state, Connection.pending(connection))}
        else
          _ ->
            Connection.close(connection)
            schedule_connect(state)
        end

      {:error, _reason} ->
        schedule_connect(state)
    end
  end

  def handle_info({:stream_opened, _reference, {:ok, connection}}, state) do
    Connection.close(connection)
    {:noreply, state}
  end

  def handle_info({:stream_opened, _reference, _result}, state), do: {:noreply, state}

  def handle_info(
        {:DOWN, monitor, :process, worker, _reason},
        %{opening: {_reference, worker, monitor}} = state
      ),
      do: schedule_connect(retire_opening_connection(%{state | opening: nil}))

  def handle_info({:channel_output, pid, channel, reference, frame}, state) do
    case {state.phase, state.channels[channel]} do
      {:authenticated, %{pid: ^pid}} ->
        case Connection.send_frame(state.websocket, {:binary, frame}) do
          :ok ->
            send(pid, {:delivered, reference})
            {:noreply, state}

          {:error, _reason} ->
            {:noreply, disconnected(state, :transport_error)}
        end

      _ ->
        {:noreply, state}
    end
  end

  def handle_info({:channel_closed, channel, reason}, state) do
    {entry, channels} = Map.pop(state.channels, channel)
    state = %{state | channels: channels}

    if entry do
      control = Codec.encode_control_frame(%{type: :closed, channel: channel, reason: reason})
      maybe_send(state.websocket, control)
    end

    {:noreply, state}
  end

  def handle_info({:channel_input_ack, pid, channel, frames, bytes}, state) do
    with %{pid: ^pid} = entry <- state.channels[channel],
         {:ok, window} <- Window.acknowledge(entry.input_window, frames, bytes) do
      reply(state, %{type: :input_ack, channel: channel, frames: frames, bytes: bytes})
      {:noreply, put_in(state, [:channels, channel, :input_window], window)}
    else
      _ -> {:noreply, state}
    end
  end

  def handle_info({:EXIT, pid, _reason}, state) do
    channels = Map.reject(state.channels, fn {_number, entry} -> entry.pid == pid end)
    guests = Map.reject(state.guests, fn {_key, entry} -> entry.pid == pid end)
    {:noreply, %{state | channels: channels, guests: guests}}
  end

  def handle_info({:guest_actor_gone, manager}, state) do
    retired = for {channel, entry} <- state.channels, entry[:manager] == manager, do: channel

    Enum.each(retired, fn channel ->
      Channel.stop(state.channels[channel].pid)
      reply(state, %{type: :closed, channel: channel, reason: :fenced})
    end)

    {:noreply,
     %{
       state
       | channels: Map.drop(state.channels, retired),
         guests: Map.reject(state.guests, fn {_key, entry} -> entry.pid == manager end)
     }}
  end

  # @cc [owner:ghuntley,label:recovery;capacity] terminal-managers-retire-with-authority
  # Idle manager/socket state MUST be reclaimed when its placement ceases to be
  # the VM's unique runnable authority. Reclamation closes attached channels but
  # MUST NOT terminate the independently supervised guest or persistent PTYs.
  def handle_info(:reap_guests, state) do
    Process.send_after(self(), :reap_guests, 5000)

    keys =
      Enum.uniq(
        Map.keys(state.guests) ++ Enum.map(state.channels, fn {_, entry} -> entry.identity end)
      )

    next =
      Enum.reduce(keys, state, fn {vm, placement, epoch} = key, acc ->
        case Lilly.Control.Runtime.terminal_actor(state.runtime, vm, placement, epoch) do
          {:ok, _actor} ->
            acc

          _ ->
            retired = for {channel, entry} <- acc.channels, entry.identity == key, do: channel

            Enum.each(retired, fn channel ->
              Channel.stop(acc.channels[channel].pid)
              reply(acc, %{type: :closed, channel: channel, reason: :fenced})
            end)

            acc = %{acc | channels: Map.drop(acc.channels, retired)}
            drop_guest(acc, %{vm_id: vm, placement_id: placement, execution_epoch: epoch})
        end
      end)

    {:noreply, next}
  end

  def handle_info({:android_display_frame, channel, generation, bytes}, state)
      when is_integer(channel) and is_integer(generation) and is_binary(bytes) do
    state =
      case state.android_channels[channel] do
        %{generation: ^generation} -> reply_data(state, channel, bytes)
        _ -> state
      end

    {:noreply, state}
  end

  def handle_info({:android_display_closed, channel, generation, _reason}, state) do
    if match?(%{generation: ^generation}, state.android_channels[channel]),
      do: reply(state, %{type: :closed, channel: channel, reason: :dial_failed})

    {:noreply, %{state | android_channels: Map.delete(state.android_channels, channel)}}
  end

  def handle_info(message, %{websocket: %Connection{} = connection} = state),
    do: {:noreply, transport(state, Connection.stream(connection, message))}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    case state.opening do
      {_reference, worker, monitor} ->
        Process.demonitor(monitor, [:flush])
        Process.exit(worker, :kill)

      _ ->
        :ok
    end

    retire_opening_connection(state)
    if state.websocket, do: Connection.close(state.websocket)

    Enum.each(state.android_channels, fn {_channel, entry} ->
      _ = Lilly.Terminal.AndroidDisplay.stop(entry.pid)
    end)

    :ok
  end

  # Applies one transport result: decoded frames feed the terminal codec in
  # order; a close, a lost transport or an undecodable frame disconnects.
  @spec transport(map(), term()) :: map()
  defp transport(state, :unknown), do: state
  defp transport(state, {:closed, _connection}), do: disconnected(state, :closed)
  defp transport(state, {:error, _connection, _reason}), do: disconnected(state, :protocol_error)

  defp transport(state, {:ok, connection, frames}) do
    Enum.reduce_while(frames, %{state | websocket: connection}, fn frame, state ->
      case frame do
        {:binary, bytes} ->
          state = buffer(state, bytes)
          if state.phase == :disconnected, do: {:halt, state}, else: {:cont, state}

        {:close, _code, _reason} ->
          {:halt, disconnected(state, :closed)}

        _other ->
          {:cont, state}
      end
    end)
  end

  @spec open(Lilly.Control.Client.t(), pid(), reference()) ::
          {:ok, Connection.t()} | {:error, term()}
  defp open(client, owner, reference) do
    with {:ok, connection} <-
           Connection.open(client.base_url, "/api/provisioners/v4/stream",
             headers: [{"authorization", "Lilly " <> client.token}],
             cacertfile: client.cacertfile,
             allow_insecure_loopback: client.allow_insecure_loopback,
             limit: @frame_limit,
             activate: false
           ) do
      with :ok <- GenServer.call(owner, {:opening_connection, reference, connection}, :infinity),
           :ok <- Connection.handoff(connection, owner) do
        {:ok, connection}
      else
        error ->
          Connection.close(connection)
          error
      end
    end
  catch
    _, _ -> {:error, :transport_error}
  end

  @spec retire_opening_connection(map()) :: map()
  defp retire_opening_connection(state) do
    if state.opening_connection, do: Connection.close(state.opening_connection)
    %{state | opening_connection: nil}
  end

  @impl true
  def format_status(_opt, state) do
    %{
      data: [
        {"State",
         %{
           phase: state.phase,
           channels: map_size(state.channels),
           guests: map_size(state.guests),
           next_channel: state.next_channel
         }}
      ]
    }
  end

  defp buffer(state, bytes) do
    consume(%{state | buffer: state.buffer <> bytes})
  end

  defp consume(state) do
    case Codec.decode_frame_prefix(state.buffer) do
      {:ok, %{channel: 0, message: control}, trailing} ->
        state = control(%{state | buffer: trailing}, control)
        if state.phase == :disconnected, do: state, else: consume(state)

      {:ok, %{channel: channel, sequence: sequence, bytes: bytes}, trailing}
      when state.phase == :authenticated ->
        state = data(state, channel, sequence, bytes)
        consume(%{state | buffer: trailing})

      :partial ->
        state

      {:error, _reason} ->
        disconnected(state, :protocol_error)

      _unauthenticated_frame ->
        disconnected(state, :protocol_error)
    end
  end

  defp data(state, channel, sequence, bytes) do
    case state.channels[channel] do
      %{pid: pid, last_input: last} when sequence > last ->
        case Window.take(state.channels[channel].input_window, byte_size(bytes)) do
          {:ok, window} when sequence == last + 1 ->
            _ = Channel.input(pid, sequence, bytes)

            state
            |> put_in([:channels, channel, :last_input], sequence)
            |> put_in([:channels, channel, :input_window], window)

          _ ->
            Channel.stop(pid)
            reply(state, %{type: :closed, channel: channel, reason: :fenced})
            %{state | channels: Map.delete(state.channels, channel)}
        end

      _ ->
        case state.android_channels[channel] do
          %{pid: pid, generation: generation, last_input: last}
          when is_integer(generation) and sequence == last + 1 ->
            _ = Lilly.Terminal.AndroidDisplay.input(pid, bytes)
            put_in(state, [:android_channels, channel, :last_input], sequence)

          _ ->
            state
        end
    end
  end

  defp control(%{phase: :authenticating} = state, %{type: :hello_response}) do
    Logger.metadata(terminal_stream: true)
    :ok = log_connected(state)
    send(state.runtime, {:terminal_stream_ready, self(), true})

    %{
      state
      | phase: :authenticated,
        heartbeat_sent: 0,
        heartbeat_acked: 0,
        heartbeat_at: System.monotonic_time(:millisecond)
    }
  end

  defp control(%{phase: :authenticating} = state, _message),
    do: disconnected(state, :protocol_error)

  defp control(%{phase: :authenticated} = state, %{type: :hello_response}),
    do: disconnected(state, :protocol_error)

  defp control(%{phase: :authenticated} = state, %{type: :heartbeat_reply, sequence: sequence})
       when sequence > state.heartbeat_acked and sequence <= state.heartbeat_sent do
    %{state | heartbeat_acked: sequence, heartbeat_at: System.monotonic_time(:millisecond)}
  end

  defp control(state, %{type: :create} = message) do
    channel = message.channel

    {result, state} =
      guest_call(state, message, fn guest ->
        Guest.create(
          guest,
          message.user,
          message.term,
          message.cols,
          message.rows,
          message.request_id
        )
      end)

    case result do
      {:ok, created} ->
        reply(state, %{
          type: :created,
          request_id: message.request_id,
          ok: true,
          channel: channel,
          guest_session_id: created.guest_session_id,
          reason: nil
        })

        state

      {:error, reason} ->
        reply(state, %{
          type: :created,
          request_id: message.request_id,
          ok: false,
          channel: channel,
          guest_session_id: nil,
          reason: created_reason(reason)
        })

        drop_guest(state, message)
    end
  end

  defp control(state, %{type: :attach} = message) do
    channel = message.channel
    identity_key = {message.vm_id, message.placement_id, message.execution_epoch}

    {result, state} =
      guest_call(state, message, fn guest ->
        Guest.attach(guest, message.guest_session_id, message.mode, message.cursor,
          cols: message.cols,
          rows: message.rows
        )
      end)

    case result do
      {:ok, attach} ->
        {:ok, pid} =
          Channel.start_link(
            self(),
            attach.socket,
            channel
          )

        :ok = :gen_tcp.controlling_process(attach.socket, pid)
        send(pid, {:activate, attach.replay})

        reply(state, %{
          type: :attached,
          replay_bytes: attach.replay_bytes,
          channel: channel,
          ok: true,
          guest_session_id: message.guest_session_id,
          from: attach.from,
          reason: nil
        })

        put_in(state, [:channels, channel], %{
          pid: pid,
          last_input: 0,
          input_window: Window.new(),
          manager: state.guests[identity_key].pid,
          identity: identity_key,
          guest_session_id: message.guest_session_id
        })

      {:error, reason} ->
        reply(state, %{
          type: :attached,
          replay_bytes: 0,
          channel: channel,
          ok: false,
          guest_session_id: nil,
          from: nil,
          reason: attached_reason(reason)
        })

        drop_guest(state, message)
    end
  end

  defp control(state, %{type: :channel_close} = message) do
    case Map.pop(state.channels, message.channel) do
      {nil, _} ->
        state

      {entry, channels} ->
        _ = Channel.stop(entry.pid)
        %{state | channels: channels}
    end
  end

  defp control(state, %{type: :output_ack} = message) do
    case state.channels[message.channel] do
      %{pid: pid} -> Channel.consumed(pid, message.frames, message.bytes)
      _ -> :ok
    end

    state
  end

  defp control(state, %{type: :users} = message) do
    {result, state} = guest_call(state, message, &Guest.users/1)

    case result do
      {:ok, users} -> reply(state, %{type: :users_listed, vm_id: message.vm_id, users: users})
      _ -> :ok
    end

    state
  end

  defp control(state, %{type: :listing} = message) do
    {result, state} = guest_call(state, message, &Guest.list/1)

    case result do
      {:ok, sessions} ->
        reply(state, %{type: :listed, vm_id: message.vm_id, sessions: sessions})
        state

      {:error, _reason} ->
        # Failure is not evidence that the guest has no sessions. Let the
        # bounded request expire rather than publishing an empty inventory.
        state
    end
  end

  defp control(state, %{type: :creation_query} = message) do
    {result, state} = guest_call(state, message, &Guest.creation_status(&1, message.request_id))

    case result do
      {:ok, result} ->
        reply(state, Map.merge(result, %{type: :creation_status, request_id: message.request_id}))
        state

      _ ->
        state
    end
  end

  defp control(state, %{type: :creation_cancel} = message) do
    {result, state} = guest_call(state, message, &Guest.cancel_creation(&1, message.request_id))

    case result do
      :ok ->
        reply(state, %{type: :creation_cancelled, request_id: message.request_id, ok: true})
        state

      _ ->
        state
    end
  end

  defp control(state, %{type: :kill} = message) do
    {result, state} =
      guest_call(state, message, fn guest ->
        with {:ok, sessions} <- Guest.list(guest) do
          if Enum.any?(sessions, &(&1.guest_session_id == message.guest_session_id and &1.alive)) do
            Guest.kill(guest, message.guest_session_id)
          else
            :ok
          end
        end
      end)

    # Absence from a successful authenticated listing confirms an already
    # completed kill. Dial/list failures never manufacture that acknowledgement.
    reply(state, message |> Map.put(:type, :killed) |> Map.put(:ok, result == :ok))

    case result do
      :ok -> state
      _ -> drop_guest(state, message)
    end
  end

  defp control(state, %{type: :resize} = message) do
    case guest_call(
           state,
           message,
           &Guest.resize(&1, message.guest_session_id, message.cols, message.rows)
         ) do
      {:ok, state} -> state
      {_, state} -> drop_guest(state, message)
    end
  end

  defp control(state, %{type: :android_display_open} = message) do
    result =
      with {:ok, identity} <- terminal_identity(state, message),
           {:ok, config} <- Lilly.Control.Runtime.network_config(state.runtime),
           {:ok, guest} <- Lilly.Network.Guest.new(message.vm_id, identity.profile, identity.slot),
           {:ok, pid} <-
             Lilly.Terminal.AndroidDisplay.start_link(
               self(),
               config,
               guest,
               %{ticket: message.ticket, mode: message.mode},
               message.generation,
               message.channel
             ) do
        {:ok, pid}
      else
        _ -> {:error, :display_unavailable}
      end

    case result do
      {:ok, pid} ->
        reply(state, %{
          type: :android_display_opened,
          channel: message.channel,
          generation: message.generation,
          ok: true,
          reason: nil
        })

        put_in(state, [:android_channels, message.channel], %{
          pid: pid,
          generation: message.generation,
          last_input: 0
        })

      {:error, reason} ->
        reply(state, %{
          type: :android_display_opened,
          channel: message.channel,
          generation: message.generation,
          ok: false,
          reason: reason
        })

        state
    end
  end

  defp control(state, %{type: :android_display_close, channel: channel}) do
    case Map.pop(state.android_channels, channel) do
      {nil, _} ->
        state

      {%{pid: pid}, channels} ->
        _ = Lilly.Terminal.AndroidDisplay.terminate(pid)
        %{state | android_channels: channels}
    end
  end

  defp control(state, %{type: :boot_log} = message) do
    result =
      with {:ok, actor} <-
             Lilly.Control.Runtime.terminal_actor(
               state.runtime,
               message.vm_id,
               message.placement_id,
               message.execution_epoch
             ),
           do: Lilly.VM.Actor.boot_log(actor, message.vm_id, message.cursor)

    case result do
      {:ok, tail} ->
        reply(state, %{
          type: :boot_log_data,
          vm_id: message.vm_id,
          next: tail.next,
          bytes: tail.bytes
        })

        state

      {:error, _reason} ->
        reply(state, %{
          type: :boot_log_data,
          vm_id: message.vm_id,
          next: message.cursor,
          bytes: ""
        })

        state
    end
  end

  defp control(state, _unknown), do: state

  defp created_reason(:rejected), do: :rejected
  defp created_reason(:limit), do: :limit
  defp created_reason(_), do: :dial_failed

  defp attached_reason(:rejected), do: :rejected
  defp attached_reason(:unknown_session), do: :not_found
  defp attached_reason(:terminal_unavailable), do: :fenced
  defp attached_reason(_), do: :dial_failed

  # @cc [owner:ghuntley,label:recovery] failed-control-retains-manager-ownership
  # Once a manager is started, failed guest operations MUST retain or explicitly
  # dispose that manager in the returned stream state; retries MUST NOT leak
  # untracked linked managers. Actor authorization precedes every operation.
  @spec guest_call(map(), map(), (pid() -> result)) :: {result | {:error, atom()}, map()}
        when result: var
  defp guest_call(state, message, operation) do
    case ensure_guest(state, message) do
      {:ok, guest, _identity_key, next} -> {operation.(guest), next}
      {:error, reason} -> {{:error, reason}, state}
    end
  end

  # @cc [owner:ghuntley,label:recovery] guest-manager-current-boot
  # Reusing a placement/epoch MUST NOT reuse a manager from an earlier boot.
  # Cache identity MUST include the actor-authorized boot challenge; a changed
  # challenge disposes only the old control manager, never the guest VM or PTYs.
  defp ensure_guest(state, message) do
    identity_key = {message.vm_id, message.placement_id, message.execution_epoch}

    with {:ok, identity} <- terminal_identity(state, message) do
      boot = :crypto.hash(:sha256, identity.boot_challenge)

      case state.guests[identity_key] do
        %{pid: pid, boot: ^boot} when is_pid(pid) ->
          {:ok, pid, identity_key, state}

        _ ->
          state = drop_guest(state, message)

          case Guest.start_link(self(), identity) do
            {:ok, pid} ->
              guests = Map.put(state.guests, identity_key, %{pid: pid, boot: boot})
              {:ok, pid, identity_key, %{state | guests: guests}}

            {:error, _reason} ->
              {:error, :terminal_unavailable}
          end
      end
    end
  end

  defp terminal_identity(state, message) do
    placement = message.placement_id
    epoch = message.execution_epoch

    result =
      with {:ok, actor} <- Lilly.Control.Runtime.terminal_actor(state.runtime, message.vm_id),
           {:ok, identity} <- Lilly.VM.Actor.terminal_identity(actor, message.vm_id),
           do: {:ok, Map.merge(identity, %{actor_pid: actor, host_id: state.client.host_id})}

    case result do
      {:ok, %{placement_id: ^placement, execution_epoch: ^epoch} = identity} ->
        {:ok, identity}

      {:ok, _other} ->
        {:error, :fenced}

      {:error, _reason} ->
        {:error, :terminal_unavailable}
    end
  end

  defp drop_guest(state, message) do
    identity_key = {message.vm_id, message.placement_id, message.execution_epoch}

    case Map.pop(state.guests, identity_key) do
      {nil, _guests} ->
        state

      {%{pid: pid}, guests} ->
        _ = Process.exit(pid, :kill)
        %{state | guests: guests}
    end
  end

  defp reply(state, control) do
    maybe_send(state.websocket, Codec.encode_control_frame(control))
  end

  defp reply_data(state, channel, bytes) do
    sequence = Map.get(state.android_channels[channel], :output_sequence, 0) + 1
    maybe_send(state.websocket, Codec.encode_data_frame(channel, sequence, bytes))
    put_in(state, [:android_channels, channel, :output_sequence], sequence)
  end

  defp maybe_send(%Connection{} = websocket, frame) do
    case Connection.send_frame(websocket, {:binary, frame}) do
      :ok -> :ok
      {:error, _reason} -> :ok
    end
  end

  defp maybe_send(nil, _frame), do: :ok

  defp schedule_connect(state) do
    backoff = min(state.backoff * 2, @dial_backoff_max)
    Process.send_after(self(), :connect, state.backoff)
    {:noreply, %{state | backoff: backoff, phase: :disconnected}}
  end

  defp disconnected(state, reason) do
    if reason in [:transport_error, :protocol_error],
      do: Lilly.Terminal.Metrics.proxy_error(state.client.host_id)

    authenticated? = state.phase == :authenticated
    send(state.runtime, {:terminal_stream_ready, self(), false})

    if authenticated? do
      Lilly.Events.emit("lilly.terminal_stream_lost",
        host_id: state.client.host_id,
        reason: reason
      )
    end

    if state.websocket, do: Connection.close(state.websocket)
    Enum.each(state.channels, fn {_channel, entry} -> _ = Channel.stop(entry.pid) end)

    Enum.each(state.android_channels, fn {_channel, entry} ->
      _ = Lilly.Terminal.AndroidDisplay.stop(entry.pid)
    end)

    Process.send_after(self(), :connect, state.backoff)

    %{
      state
      | websocket: nil,
        phase: :disconnected,
        buffer: <<>>,
        channels: %{},
        android_channels: %{}
    }
  end

  defp log_connected(state) do
    Lilly.Events.emit("lilly.terminal_stream_connected", host_id: state.client.host_id)
  end
end
