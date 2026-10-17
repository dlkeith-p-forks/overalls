defmodule OverallsProtocol.Control.Client do
  @moduledoc """
  One control WebSocket to Marshall, shared by every service client.

  The client connects, sends `hello`, waits for `welcome`, then serves
  correlated requests, heartbeats and pushed hints. Its owner receives:

      {:control, client, {:connected, welcome}}
      {:control, client, {:hint, kind, id}}       # kind and id are strings
      {:control, client, :resync}                 # re-read everything you hold
      {:control, client, {:disconnected, reason}} # reason is a Close reason or :lost

  A connect always produces `:connected`, after which the owner re-reads
  durable state, so hints lost while disconnected never matter.
  """
  use GenServer

  alias OverallsProtocol.Control.{Close, Envelope}
  alias OverallsProtocol.WebSocket.Connection

  @path "/api/control/v1"
  @version_header "overalls-control"
  @initial_backoff 1_000
  # Reconnection is bounded like Lilly's report retry (ADR-0140): a longer gap
  # after a Marshall restart would outlast capacity freshness for no benefit.
  @max_backoff 4_000
  @in_flight 8
  @max_in_flight 256

  @type option ::
          {:url, String.t()}
          | {:service, String.t()}
          | {:credential, (-> {:ok, String.t()} | {:error, term()})}
          | {:bind, (-> map())}
          | {:owner, pid()}
          | {:cacertfile, String.t()}
          | {:allow_insecure_loopback, boolean()}
          | {:limit, pos_integer()}
          | {:name, GenServer.name()}
  @type request_error :: :disconnected | :unproven | :timeout | :busy | String.t()

  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(options) do
    options = Keyword.put_new(options, :owner, self())

    case Keyword.fetch(options, :name) do
      {:ok, name} -> GenServer.start_link(__MODULE__, options, name: name)
      :error -> GenServer.start_link(__MODULE__, options)
    end
  end

  # @cc [owner:ghuntley,label:protocol;recovery] control-request-no-hidden-redelivery
  # request/4 MUST NOT queue while disconnected and MUST NOT resend: a request
  # whose connection drops before its response resolves as :unproven, and the
  # caller's own idempotent cadence re-establishes state. Pending requests MUST
  # NOT exceed the welcome's integer `in_flight` limit between 1 and 256.
  # Missing or invalid advertised limits MUST use the default of eight.
  @doc "Sends one request and waits for its response."
  @spec request(GenServer.server(), String.t(), map(), timeout()) ::
          {:ok, map()} | {:error, request_error()}
  def request(client, op, body, timeout \\ 5_000) do
    GenServer.call(client, {:request, op, body, timeout}, timeout + 1_000)
  catch
    :exit, {:timeout, _} -> {:error, :timeout}
    :exit, _ -> {:error, :disconnected}
  end

  @doc "Whether the client currently holds a welcomed connection."
  @spec ready?(GenServer.server()) :: boolean()
  def ready?(client), do: GenServer.call(client, :ready?)

  @doc "`:ready`, or `{:disconnected, reason}` with the last close reason (nil before any)."
  @spec status(GenServer.server()) :: :ready | {:disconnected, Close.reason() | :lost | nil}
  def status(client), do: GenServer.call(client, :status)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)

    state = %{
      options: options,
      owner: Keyword.fetch!(options, :owner),
      connection: nil,
      phase: :disconnected,
      backoff: @initial_backoff,
      next_id: 1,
      pending: %{},
      heartbeat_timer: nil,
      opening: nil,
      opening_connection: nil,
      in_flight: @in_flight,
      heartbeat_ms: 5_000,
      last_seen: 0,
      ping: 0,
      last_close: nil
    }

    {:ok, state, {:continue, :connect}}
  end

  @impl true
  def handle_continue(:connect, state), do: {:noreply, connect(state)}

  @impl true
  def handle_call(:ready?, _from, state), do: {:reply, state.phase == :ready, state}

  def handle_call(:status, _from, %{phase: :ready} = state), do: {:reply, :ready, state}
  def handle_call(:status, _from, state), do: {:reply, {:disconnected, state.last_close}, state}

  # @cc [owner:ghuntley,label:recovery] control-opening-socket-custody
  # The current worker MUST register its passive socket before transferring it.
  # Worker death or failed completion MUST close that registered socket; stale
  # workers MUST NOT transfer their transport into this client.
  def handle_call(
        {:opening_connection, ref, %Connection{} = connection},
        {worker, _tag},
        %{opening: {ref, worker, _monitor}, opening_connection: nil} = state
      ),
      do: {:reply, :ok, %{state | opening_connection: connection}}

  def handle_call({:opening_connection, _ref, _connection}, _from, state),
    do: {:reply, :stale, state}

  def handle_call({:request, _op, _body, _timeout}, _from, %{phase: phase} = state)
      when phase != :ready,
      do: {:reply, {:error, :disconnected}, state}

  def handle_call({:request, _op, _body, _timeout}, _from, %{pending: pending} = state)
      when map_size(pending) >= state.in_flight,
      do: {:reply, {:error, :busy}, state}

  def handle_call({:request, op, body, timeout}, from, state) do
    id = state.next_id
    message = Envelope.encode({:req, %{id: id, op: op, body: body}})

    case Connection.send_frame(state.connection, {:text, message}) do
      :ok ->
        timer = Process.send_after(self(), {:request_timeout, id}, timeout)
        pending = Map.put(state.pending, id, {from, timer})
        {:noreply, %{state | next_id: id + 1, pending: pending}}

      {:error, _} ->
        {:reply, {:error, :disconnected}, lost(state, :lost)}
    end
  end

  @impl true
  def handle_info(:connect, %{phase: :stopped} = state), do: {:noreply, state}
  def handle_info(:connect, state), do: {:noreply, connect(state)}

  def handle_info({:opened, ref, result}, %{opening: {ref, _worker, monitor}} = state) do
    Process.demonitor(monitor, [:flush])
    state = %{state | opening: nil}

    state =
      case result do
        {:ok, _connection} -> %{state | opening_connection: nil}
        _ -> retire_opening_connection(state)
      end

    {:noreply, opened(state, result)}
  end

  def handle_info(
        {:DOWN, monitor, :process, worker, _reason},
        %{opening: {_ref, worker, monitor}} = state
      ),
      do: {:noreply, retry(retire_opening_connection(%{state | opening: nil}), :lost)}

  def handle_info({:opened, _ref, {:ok, connection}}, state) do
    Connection.close(connection)
    {:noreply, state}
  end

  def handle_info({:request_timeout, id}, state) do
    case Map.pop(state.pending, id) do
      {{from, _timer}, pending} ->
        GenServer.reply(from, {:error, :timeout})
        {:noreply, %{state | pending: pending}}

      {nil, _} ->
        {:noreply, state}
    end
  end

  def handle_info({:timeout, timer, :heartbeat}, %{heartbeat_timer: timer, phase: phase} = state)
      when phase in [:awaiting_welcome, :ready] do
    if now() - state.last_seen > 3 * state.heartbeat_ms do
      {:noreply, close(state, :idle)}
    else
      ping = state.ping + 1
      _ = Connection.send_frame(state.connection, {:text, Envelope.encode({:ping, ping})})
      {:noreply, arm_heartbeat(%{state | ping: ping})}
    end
  end

  def handle_info({:timeout, _timer, :heartbeat}, state), do: {:noreply, state}
  def handle_info(:heartbeat, state), do: {:noreply, state}

  def handle_info(message, %{connection: connection} = state) when connection != nil do
    case Connection.stream(connection, message) do
      {:closed, _connection} ->
        {:noreply, lost(state, :lost)}

      :unknown ->
        {:noreply, state}

      result ->
        {:noreply, frames(state, result)}
    end
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, state) do
    case state.opening do
      {_ref, worker, monitor} ->
        Process.demonitor(monitor, [:flush])
        Process.exit(worker, :kill)

      nil ->
        :ok
    end

    retire_opening_connection(state)
    if state.connection, do: Connection.close(state.connection)
    :ok
  end

  @spec frames(
          map(),
          {:ok, Connection.t(), [OverallsProtocol.WebSocket.Frame.frame()]}
          | {:error, Connection.t(), atom()}
        ) :: map()
  defp frames(state, {:ok, connection, frames}) do
    state = %{state | connection: connection, last_seen: now()}

    # Stop at the first frame that ends the connection.
    Enum.reduce_while(frames, state, fn frame, state ->
      state = frame(frame, state)
      if state.phase in [:disconnected, :stopped], do: {:halt, state}, else: {:cont, state}
    end)
  end

  defp frames(state, {:error, _connection, _reason}), do: close(state, :protocol_violation)

  # @cc [owner:ghuntley,label:recovery;protocol] control-client-connect-off-process
  # Opening the TLS connection and handshake MUST happen outside the client
  # process, so requests, status and readiness answer at once (:disconnected)
  # while a connect hangs. Only the newest attempt's socket is adopted;
  # anything else is closed.
  # Each worker MUST be linked and monitored: worker death retires the attempt
  # through existing bounded lost recovery; client termination retires its worker.
  # A passive socket MUST enter the client's retirement state before handoff,
  # so worker death between handoff and completion cannot orphan the transport.
  @spec connect(map()) :: map()
  defp connect(%{opening: nil} = state) do
    owner = self()
    ref = make_ref()
    options = state.options

    {worker, monitor} =
      :erlang.spawn_opt(
        fn -> send(owner, {:opened, ref, open(options, owner, ref)}) end,
        [:link, :monitor]
      )

    %{state | opening: {ref, worker, monitor}, phase: :connecting}
  end

  defp connect(state), do: state

  @spec open(keyword(), pid(), reference()) :: {:ok, Connection.t()} | {:error, term()}
  defp open(options, owner, ref) do
    with {:ok, token} <- Keyword.fetch!(options, :credential).(),
         {:ok, connection} <-
           Connection.open(Keyword.fetch!(options, :url), @path,
             headers: [
               {"authorization", "Bearer " <> token},
               {@version_header, "#{Envelope.version()}"},
               {"overalls-service", Keyword.fetch!(options, :service)}
             ],
             cacertfile: Keyword.get(options, :cacertfile),
             allow_insecure_loopback: Keyword.get(options, :allow_insecure_loopback, false),
             limit: Keyword.get(options, :limit, 1_048_576),
             activate: false
           ) do
      with :ok <- GenServer.call(owner, {:opening_connection, ref, connection}, :infinity),
           :ok <- Connection.handoff(connection, owner) do
        {:ok, connection}
      else
        error ->
          Connection.close(connection)
          error
      end
    end
  catch
    _, _ -> {:error, :lost}
  end

  @spec retire_opening_connection(map()) :: map()
  defp retire_opening_connection(state) do
    if state.opening_connection, do: Connection.close(state.opening_connection)
    %{state | opening_connection: nil}
  end

  @spec opened(map(), {:ok, Connection.t()} | {:error, term()}) :: map()
  defp opened(state, {:ok, connection}) do
    bind = Keyword.fetch!(state.options, :bind).()

    hello =
      Envelope.encode({:hello, %{service: Keyword.fetch!(state.options, :service), bind: bind}})

    with :ok <- Connection.send_frame(connection, {:text, hello}),
         :ok <- Connection.activate(connection) do
      state = %{state | connection: connection, phase: :awaiting_welcome, last_seen: now()}
      state = arm_heartbeat(state)
      frames(state, Connection.pending(connection))
    else
      _ ->
        Connection.close(connection)
        retry(state, :lost)
    end
  end

  defp opened(state, {:error, {:status, 426}}), do: retry(state, :unsupported_version)
  defp opened(state, {:error, {:status, 401}}), do: retry(state, :refused)
  defp opened(state, _error), do: retry(state, :lost)

  @spec frame(OverallsProtocol.WebSocket.Frame.frame(), map()) :: map()
  defp frame({:text, text}, state) do
    case Envelope.decode(text) do
      {:ok, message} -> message(message, state)
      {:error, _} -> close(state, :protocol_violation)
    end
  end

  defp frame({:close, code, _reason}, state), do: lost(state, Close.reason(code))
  defp frame(_other, state), do: close(state, :protocol_violation)

  @spec message(Envelope.message(), map()) :: map()
  defp message({:welcome, welcome}, %{phase: :awaiting_welcome} = state) do
    notify(state, {:connected, welcome})

    arm_heartbeat(%{
      state
      | phase: :ready,
        backoff: @initial_backoff,
        heartbeat_ms: welcome.heartbeat_ms,
        in_flight: in_flight(welcome.limits),
        last_close: nil
    })
  end

  defp message({:res, %{id: id, result: result}}, %{phase: :ready} = state) do
    case Map.pop(state.pending, id) do
      {{from, timer}, pending} ->
        Process.cancel_timer(timer)
        GenServer.reply(from, result)
        %{state | pending: pending}

      {nil, _} ->
        state
    end
  end

  defp message({:hint, %{kind: kind, id: id}}, %{phase: :ready} = state) do
    notify(state, {:hint, kind, id})
    state
  end

  defp message(:resync, %{phase: :ready} = state) do
    notify(state, :resync)
    state
  end

  defp message({:ping, n}, state) do
    _ = Connection.send_frame(state.connection, {:text, Envelope.encode({:pong, n})})
    state
  end

  defp message({:pong, _n}, state), do: state
  defp message(_unexpected, state), do: close(state, :protocol_violation)

  @spec in_flight(map()) :: pos_integer()
  defp in_flight(%{"in_flight" => limit})
       when is_integer(limit) and limit >= 1 and limit <= @max_in_flight,
       do: limit

  defp in_flight(_limits), do: @in_flight

  @spec close(map(), Close.reason()) :: map()
  defp close(%{connection: nil} = state, _reason), do: state

  defp close(state, reason) do
    Connection.close(state.connection, Close.code(reason))
    lost(%{state | connection: nil}, reason)
  end

  # Fails every pending request as :unproven and schedules the next attempt.
  @spec lost(map(), Close.reason() | :lost) :: map()
  defp lost(state, reason) do
    state = cancel_heartbeat(state)
    if state.connection, do: Connection.close(state.connection)

    Enum.each(state.pending, fn {_id, {from, timer}} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, {:error, :unproven})
    end)

    was_connected = state.phase != :disconnected
    state = %{state | connection: nil, pending: %{}}
    if was_connected, do: notify(state, {:disconnected, reason})
    retry(state, reason)
  end

  # @cc [owner:ghuntley,label:protocol;recovery] control-terminal-stop-never-reconnects
  # A stop reaction MUST retain the terminal refusal without scheduling another
  # connect. Already delivered connect messages MUST NOT revive a stopped client;
  # only replacing the owning client may initiate a new connection.

  # @cc [owner:ghuntley,label:recovery] control-client-bounded-reconnect
  # Recoverable losses MUST retry with full jitter from one millisecond through
  # a backoff ceiling that doubles from one second and never exceeds four seconds.
  # Draining MUST use at most 500 milliseconds. Unsupported-version refusals MUST stop.
  @spec retry(map(), Close.reason() | :lost) :: map()
  defp retry(state, reason) do
    case Close.reaction(reason) do
      :stop ->
        %{state | phase: :stopped, last_close: reason}

      reaction ->
        delay =
          if reaction == :reconnect_now,
            do: :rand.uniform(500),
            else: :rand.uniform(state.backoff)

        Process.send_after(self(), :connect, delay)

        %{
          state
          | phase: :disconnected,
            backoff: min(state.backoff * 2, @max_backoff),
            last_close: reason
        }
    end
  end

  # @cc [owner:ghuntley,label:protocol;recovery] control-heartbeat-timer-ownership
  # Exactly one timer MUST belong to the current connection. Retiring or replacing
  # its schedule MUST cancel the old timer and ignore stale delivered timer refs.
  @spec arm_heartbeat(map()) :: map()
  defp arm_heartbeat(state) do
    state = cancel_heartbeat(state)
    timer = :erlang.start_timer(state.heartbeat_ms, self(), :heartbeat)
    %{state | heartbeat_timer: timer}
  end

  @spec cancel_heartbeat(map()) :: map()
  defp cancel_heartbeat(state) do
    if is_reference(state.heartbeat_timer), do: Process.cancel_timer(state.heartbeat_timer)
    %{state | heartbeat_timer: nil}
  end

  @spec notify(map(), term()) :: :ok
  defp notify(state, event) do
    send(state.owner, {:control, self(), event})
    :ok
  end

  @spec now() :: integer()
  defp now, do: System.monotonic_time(:millisecond)
end
