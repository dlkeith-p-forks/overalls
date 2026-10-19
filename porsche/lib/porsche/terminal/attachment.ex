defmodule Porsche.Terminal.Attachment do
  @moduledoc """
  One SSH PTY attached to a shared Marshall terminal session (ADR-0223).

  The SSH channel hands its PTY to this process. It obtains a single-use
  ticket with the connection's session credential, upgrades Marshall's
  gateway stream and relays between the SSH channel and that stream:

  - input is forwarded only for writable attachments, within the
    `TerminalWindow` credit Marshall acknowledges, and the SSH window is
    re-opened only after a frame was sent, so SSH flow control applies;
  - every output frame is acknowledged only after the local SSH send
    succeeded;
  - `window_change` becomes a resize of the shared session;
  - stderr receives exactly one `TerminalAttach` header line, and the owner
    channel exits with the closed `TerminalAttach` status.

  Tickets, credentials and terminal bytes are never logged or inspected.
  """
  use GenServer, restart: :temporary
  require Porsche.Events

  alias OverallsProtocol.{SSHCommand, TerminalAttach}
  alias OverallsProtocol.WebSocket.Connection, as: WebSocket
  alias Porsche.Terminal.Credit

  @send_timeout 30_000
  @attach_timeout 10_000
  @liveness_ms 5_000
  @silence_ms 15_000

  @type connect ::
          (Porsche.Client.t(), String.t(), [{String.t(), String.t()}] ->
             {:ok, WebSocket.t()} | {:error, WebSocket.open_error()})
  @type options :: %{
          required(:owner) => pid(),
          required(:connection) => :ssh.connection_ref(),
          required(:channel) => :ssh.channel_id(),
          required(:config) => map(),
          required(:command) => SSHCommand.t(),
          required(:cols) => pos_integer(),
          required(:rows) => pos_integer()
        }
  @type phase :: :opening | :awaiting | :attached

  @doc "Starts an attachment under the attachment supervisor, owned by the calling channel."
  @spec start(options()) :: DynamicSupervisor.on_start_child()
  def start(options),
    do: DynamicSupervisor.start_child(Porsche.Terminal.Attachments, {__MODULE__, options})

  @spec start_link(options()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @doc "Forwards SSH channel input; the attachment re-opens the SSH window."
  @spec input(pid(), binary()) :: :ok
  def input(pid, bytes) when is_binary(bytes) do
    send(pid, {:ssh_input, bytes})
    :ok
  end

  @doc "Forwards an SSH window change."
  @spec resize(pid(), term(), term()) :: :ok
  def resize(pid, cols, rows) do
    send(pid, {:ssh_resize, cols, rows})
    :ok
  end

  @doc "The SSH client sent EOF or closed: detach, leaving the session running."
  @spec detach(pid()) :: :ok
  def detach(pid) do
    send(pid, :ssh_detach)
    :ok
  end

  @impl true
  def init(options) do
    # @cc [owner:ghuntley,label:security] porsche-attachment-private
    # The attachment process MUST be tagged porsche_private so every
    # uncatalogued diagnostic is redacted, MUST NOT log tickets, credentials or
    # terminal bytes, and MUST redact its state from status and crash reports.
    :logger.update_process_metadata(%{porsche_private: true})
    monitor = Process.monitor(options.owner)
    read_only = options.command.options["read-only"] == true

    cursor =
      case options.command.options["cursor"] do
        nil -> 0
        value -> String.to_integer(value)
      end

    {:ok,
     %{
       owner: options.owner,
       monitor: monitor,
       connection: options.connection,
       channel: options.channel,
       config: options.config,
       command: options.command,
       cursor: cursor,
       cols: options.cols,
       rows: options.rows,
       resized: nil,
       read_only: read_only,
       credit: Credit.new(read_only),
       phase: :opening,
       websocket: nil,
       header: false,
       heard_at: now()
     }, {:continue, :open}}
  end

  @impl true
  def handle_continue(:open, state) do
    with {:ok, token} <- session_token(state),
         {:ok, ticket} <- ticket(state, token),
         {:ok, websocket} <- open(state, token, ticket) do
      Process.send_after(self(), :attach_timeout, @attach_timeout)
      Process.send_after(self(), :liveness, @liveness_ms)
      state = %{state | websocket: websocket, phase: :awaiting, heard_at: now()}

      case WebSocket.pending(websocket) do
        {:ok, websocket, frames} -> frames(frames, %{state | websocket: websocket})
        {:error, websocket, _reason} -> finish(:transport, %{state | websocket: websocket})
      end
    else
      {:refused, error} -> finish({:refused, error}, state)
      {:outcome, outcome} -> finish(outcome, state)
    end
  end

  @impl true
  def handle_info({:ssh_input, bytes}, state) do
    # @cc [owner:ghuntley,label:security] porsche-read-only-never-sends-input
    # A read-only attachment (requested, or granted read-only by Marshall)
    # MUST NOT send any input frame; its input is discarded unread and only
    # the SSH window is re-opened so the client is never stalled.
    case Credit.push(state.credit, bytes) do
      {:ok, credit, discarded} ->
        adjust(state, discarded)
        flush(%{state | credit: credit})

      {:error, :overflow} ->
        finish(:invalid, state)
    end
  end

  def handle_info({:ssh_resize, cols, rows}, state) do
    geometry = {clamp(cols, 4096, 80), clamp(rows, 512, 24)}

    if state.phase == :attached and state.credit.mode == :rw do
      {:noreply, send_resize(state, geometry)}
    else
      {:noreply, %{state | resized: geometry}}
    end
  end

  # A client leaving before the header was written needs no header.
  def handle_info(:ssh_detach, state),
    do: finish(if(state.header, do: :closed, else: :client), state)

  def handle_info({:DOWN, monitor, :process, _pid, _reason}, %{monitor: monitor} = state),
    do: finish(:client, state)

  def handle_info(:attach_timeout, %{phase: :awaiting} = state), do: finish(:transport, state)
  def handle_info(:attach_timeout, state), do: {:noreply, state}

  # @cc [owner:ghuntley,label:recovery] porsche-attachment-liveness
  # Marshall heartbeats an attached stream every five seconds; fifteen seconds
  # without any frame MUST end the attachment as a transport failure.
  def handle_info(:liveness, state) do
    if now() - state.heard_at >= @silence_ms do
      finish(:transport, state)
    else
      Process.send_after(self(), :liveness, @liveness_ms)
      {:noreply, state}
    end
  end

  def handle_info(message, %{websocket: %WebSocket{} = websocket} = state) do
    case WebSocket.stream(websocket, message) do
      {:ok, websocket, frames} -> frames(frames, %{state | websocket: websocket, heard_at: now()})
      {:closed, websocket} -> finish(:transport, %{state | websocket: websocket})
      {:error, websocket, _reason} -> finish(:transport, %{state | websocket: websocket})
      :unknown -> {:noreply, state}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def format_status(status) do
    status
    |> Map.replace(:state, :redacted)
    |> Map.replace(:message, :redacted)
    |> Map.replace(:reason, :redacted)
    |> Map.replace(:log, [])
  end

  @impl true
  def terminate(_reason, %{websocket: %WebSocket{} = websocket}), do: WebSocket.close(websocket)
  def terminate(_reason, _state), do: :ok

  @spec session_token(map()) :: {:ok, binary()} | {:refused, TerminalAttach.error()}
  defp session_token(state) do
    case Porsche.Connection.snapshot(state.connection) do
      {:ok, %{"status" => "authenticated", "session_token" => token}} when is_binary(token) ->
        {:ok, token}

      {:ok, %{"status" => "pending"}} ->
        {:refused, :approval_required}

      {:error, :unauthorized} ->
        {:refused, :unauthorized}

      _ ->
        {:refused, :temporarily_unavailable}
    end
  end

  @spec ticket(map(), binary()) :: {:ok, binary()} | {:refused, TerminalAttach.error()}
  defp ticket(state, token) do
    command = state.command

    message = %{
      "version" => 1,
      "session_token" => token,
      "command" => %{
        "version" => 1,
        "command" => command.command,
        "arguments" => command.arguments,
        "options" => Map.delete(command.options, "json")
      }
    }

    request = Map.get(state.config, :request, &Porsche.Client.request/4)

    case request.(state.config.client, "commands", message, timeout: 5000) do
      {:ok,
       %{
         "version" => 1,
         "status" => "succeeded",
         "result" => %{"ticket" => ticket, "session_id" => session}
       }}
      when is_binary(ticket) and byte_size(ticket) in 20..64 and is_binary(session) ->
        if session in command.arguments,
          do: {:ok, ticket},
          else: {:refused, :temporarily_unavailable}

      {:ok, _other} ->
        {:refused, :temporarily_unavailable}

      {:error, reason} ->
        {:refused, refusal(reason)}
    end
  end

  @spec refusal(atom()) :: TerminalAttach.error()
  defp refusal(reason)
       when reason in [:unauthorized, :forbidden, :not_found, :terminal_unavailable],
       do: reason

  defp refusal(:invalid_request), do: :invalid_command

  defp refusal(reason) do
    if Porsche.Client.conflict?(reason), do: :conflict, else: :temporarily_unavailable
  end

  @spec open(map(), binary(), binary()) :: {:ok, WebSocket.t()} | {:outcome, atom()}
  defp open(state, token, ticket) do
    client = state.config.client
    path = TerminalAttach.stream_path(state.cursor, state.cols, state.rows)

    headers = [
      {"authorization", "Bearer " <> client.token},
      {TerminalAttach.session_header(), token},
      {TerminalAttach.ticket_header(), ticket}
    ]

    connect = Map.get(state.config, :terminal_connect, &connect/3)

    case connect.(client, path, headers) do
      {:ok, websocket} -> {:ok, websocket}
      {:error, {:status, status}} -> {:outcome, TerminalAttach.status_outcome(status)}
      {:error, _reason} -> {:outcome, :transport}
    end
  end

  @spec connect(Porsche.Client.t(), String.t(), [{String.t(), String.t()}]) ::
          {:ok, WebSocket.t()} | {:error, WebSocket.open_error()}
  defp connect(client, path, headers) do
    options = [headers: headers, timeout: 5000, limit: 1_048_576]

    options =
      if client.cacertfile, do: [cacertfile: client.cacertfile] ++ options, else: options

    WebSocket.open(client.origin, path, options)
  end

  @spec frames([OverallsProtocol.WebSocket.Frame.frame()], map()) ::
          {:noreply, map()} | {:stop, :normal, map()}
  defp frames([], state), do: {:noreply, state}

  defp frames([frame | rest], state) do
    case frame(frame, state) do
      {:ok, state} -> frames(rest, state)
      {:finish, outcome, state} -> finish(outcome, state)
    end
  end

  defp frame({:text, text}, state) when byte_size(text) <= 4096 do
    case JSON.decode(text) do
      {:ok, %{"op" => "attached", "from" => from, "replay_bytes" => replay, "mode" => mode}}
      when state.phase == :awaiting and is_integer(from) and from >= 0 and is_integer(replay) and
             replay >= 0 and mode in ["rw", "ro"] ->
        attached(state, from, replay, if(mode == "rw", do: :rw, else: :ro))

      {:ok, %{"op" => "input_ack", "frames" => frames, "bytes" => bytes}}
      when state.phase == :attached ->
        case Credit.acknowledge(state.credit, frames, bytes) do
          {:ok, credit} ->
            case flush(%{state | credit: credit}) do
              {:noreply, state} -> {:ok, state}
              {:stop, :normal, state} -> {:finish, :done, state}
            end

          {:error, _} ->
            {:finish, :invalid, state}
        end

      {:ok, %{"op" => "heartbeat"}} ->
        {:ok, state}

      _ ->
        {:ok, state}
    end
  end

  # @cc [owner:ghuntley,label:protocol;capacity] porsche-output-ack-after-send
  # Output credit MUST be returned to Marshall only after the bytes were
  # accepted by the local SSH channel; a failed or timed-out send MUST end the
  # attachment without acknowledging those bytes.
  defp frame({:binary, bytes}, %{phase: :attached} = state) do
    case :ssh_connection.send(state.connection, state.channel, 0, bytes, @send_timeout) do
      :ok ->
        {credit, receipt} = Credit.delivered(state.credit, byte_size(bytes))

        ack =
          JSON.encode!(%{
            "op" => "output_ack",
            "frames" => receipt.frames,
            "bytes" => receipt.bytes
          })

        case WebSocket.send_frame(state.websocket, {:text, ack}) do
          :ok -> {:ok, %{state | credit: credit}}
          {:error, _} -> {:finish, :transport, state}
        end

      _ ->
        {:finish, :client, state}
    end
  end

  defp frame({:binary, _bytes}, state), do: {:finish, :transport, state}

  defp frame({:close, code, _reason}, state) do
    outcome = TerminalAttach.close_outcome(code)

    # A stream closed before it attached is never a successful attachment.
    if state.phase != :attached and outcome == :closed,
      do: {:finish, :transport, state},
      else: {:finish, outcome, state}
  end

  defp frame(_frame, state), do: {:ok, state}

  defp attached(state, from, replay, granted) do
    {credit, discarded} = Credit.grant(state.credit, granted)
    mode = credit.mode

    case write_header(state, {:attached, %{from: from, replay_bytes: replay, mode: mode}}) do
      :ok ->
        Porsche.Events.emit("porsche.terminal_attached", mode: mode)
        # Input typed while attaching is discarded by a read-only grant.
        adjust(state, discarded)
        state = %{state | phase: :attached, credit: credit, header: true}

        state =
          case state.resized do
            {_, _} = geometry when mode == :rw -> send_resize(state, geometry)
            _ -> state
          end

        case flush(state) do
          {:noreply, state} -> {:ok, state}
          {:stop, :normal, state} -> {:finish, :done, state}
        end

      :error ->
        {:finish, :client, state}
    end
  end

  # @cc [owner:ghuntley,label:capacity;protocol] porsche-input-window-gated
  # Input frames MUST each take TerminalWindow credit (Credit.take/1) before
  # they are sent; when credit is exhausted input waits, with the SSH window
  # still closed for it, until Marshall's cumulative input_ack returns credit.
  @spec flush(map()) :: {:noreply, map()} | {:stop, :normal, map()}
  defp flush(%{phase: :attached} = state) do
    {frames, credit} = Credit.take(state.credit)
    send_input(frames, %{state | credit: credit})
  end

  defp flush(state), do: {:noreply, state}

  defp send_input([], state), do: {:noreply, state}

  defp send_input([frame | rest], state) do
    case WebSocket.send_frame(state.websocket, {:binary, frame}) do
      :ok ->
        adjust(state, byte_size(frame))
        send_input(rest, state)

      {:error, _} ->
        finish(:transport, state)
    end
  end

  defp send_resize(state, {cols, rows}) do
    message = JSON.encode!(%{"op" => "resize", "cols" => cols, "rows" => rows})
    _ = WebSocket.send_frame(state.websocket, {:text, message})
    %{state | resized: nil}
  end

  defp adjust(_state, 0), do: :ok

  defp adjust(state, bytes) do
    _ = :ssh_connection.adjust_window(state.connection, state.channel, bytes)
    :ok
  end

  @spec write_header(map(), TerminalAttach.header()) :: :ok | :error
  defp write_header(state, header) do
    case :ssh_connection.send(
           state.connection,
           state.channel,
           1,
           TerminalAttach.encode(header),
           @send_timeout
         ) do
      :ok -> :ok
      _ -> :error
    end
  end

  # @cc [owner:ghuntley,label:protocol;security] porsche-attachment-exit
  # Every attachment MUST end by writing at most one header line (a refusal
  # header when none was written), emitting one detached event with a closed
  # reason, closing the stream and telling its owner the TerminalAttach exit
  # status. Losing the owner channel only detaches; the session keeps running.
  @spec finish(
          TerminalAttach.outcome() | :client | :done | {:refused, TerminalAttach.error()},
          map()
        ) :: {:stop, :normal, map()}
  defp finish(:done, state), do: {:stop, :normal, state}

  defp finish(result, state) do
    {outcome, error} =
      case result do
        {:refused, error} -> {TerminalAttach.error_outcome(error), error}
        :client -> {:closed, nil}
        outcome -> {outcome, nil}
      end

    if not state.header and result != :client do
      _ = write_header(state, {:refused, error || header_error(outcome)})
    end

    if state.websocket, do: WebSocket.close(state.websocket, 1000)

    Porsche.Events.emit("porsche.terminal_detached",
      reason: if(result == :client, do: :client, else: outcome)
    )

    send(state.owner, {:terminal_attachment, self(), TerminalAttach.exit_status(outcome)})
    {:stop, :normal, %{state | websocket: nil, header: true}}
  end

  @spec header_error(TerminalAttach.outcome()) :: TerminalAttach.error()
  defp header_error(:refused), do: :forbidden
  defp header_error(:authority), do: :unauthorized
  defp header_error(:invalid), do: :invalid_command
  defp header_error(_outcome), do: :transport_error

  defp clamp(value, maximum, _default) when is_integer(value) and value > 0,
    do: min(value, maximum)

  defp clamp(_value, _maximum, default), do: default

  defp now, do: System.monotonic_time(:millisecond)
end
