defmodule Marshall.Terminal.Relay do
  @moduledoc "Registry of connected host terminal streams and bounded control RPC over them."
  use GenServer

  @timeout 5000

  @type reply :: {:ok, map()} | {:error, atom()}
  @type request :: %{
          required(:caller) => pid(),
          required(:ref) => reference(),
          required(:message) => map(),
          optional(:reply_to) => reference(),
          optional(:channel) => pos_integer(),
          optional(:expiry) => reference()
        }

  # @cc [owner:ghuntley,label:recovery] relay-registry-handles-stream-loss
  # The registry MUST monitor every registered stream and forget it on any
  # exit; control calls against absent streams MUST fail closed promptly
  # instead of queueing.
  def start_link(options \\ []) do
    GenServer.start_link(__MODULE__, %{}, Keyword.put_new(options, :name, __MODULE__))
  end

  @spec register(GenServer.server(), String.t(), pid()) :: :ok
  def register(relay \\ __MODULE__, host_id, pid) do
    GenServer.call(relay, {:register, host_id, pid})
  end

  @spec register_authenticated(String.t(), pid(), String.t(), pos_integer()) ::
          :ok | {:error, atom()}
  def register_authenticated(host_id, pid, session_id, epoch),
    do: GenServer.call(__MODULE__, {:register_authenticated, host_id, pid, session_id, epoch})

  @spec stream_for(GenServer.server(), String.t()) :: {:ok, pid()} | {:error, :stream_unavailable}
  def stream_for(relay \\ __MODULE__, host_id) do
    case GenServer.call(relay, {:stream_for, host_id}) do
      {:remote, location} -> Marshall.Terminal.Remote.start(self(), location)
      result -> result
    end
  end

  @spec ready?(GenServer.server(), String.t()) :: boolean()
  def ready?(relay \\ __MODULE__, host_id) do
    case GenServer.call(relay, {:stream_for, host_id}) do
      {:ok, _pid} -> true
      {:remote, _location} -> true
      _ -> false
    end
  end

  @spec local_stream(String.t(), String.t()) :: {:ok, pid()} | {:error, atom()}
  def local_stream(host_id, nonce),
    do: GenServer.call(__MODULE__, {:local_stream, host_id, nonce})

  @spec renew(String.t(), pid()) :: :ok | {:error, term()}
  def renew(host_id, pid), do: GenServer.call(__MODULE__, {:renew, host_id, pid})

  # @cc [owner:ghuntley,label:recovery] terminal-control-reply-lifetime
  # A completed or timed-out control MUST leave no matching replies in the
  # caller mailbox and MUST reject future replies for that request. Unrelated
  # messages and the caller PID used for peer ownership MUST remain unchanged.
  @spec control(pid(), map()) :: reply()
  def control(stream, message) do
    ref = :erlang.alias()
    request = %{ref: ref, caller: self(), reply_to: ref, message: message}

    try do
      send(stream, {:relay_control, request})

      receive do
        {:relay_reply, ^ref, {:ok, reply}} -> {:ok, reply}
        {:relay_reply, ^ref, {:error, reason}} -> {:error, reason}
      after
        @timeout -> {:error, :stream_timeout}
      end
    after
      :erlang.unalias(ref)
      flush_replies(ref)
    end
  end

  # @cc [owner:ghuntley,label:recovery] terminal-control-reply-destination
  # Control responses, including errors and shutdown responses, MUST use the
  # supplied reply alias. Requests without an alias retain PID delivery for
  # viewer attachments and peer sockets; caller remains their owner identity.
  @spec reply(request(), reply()) :: :ok
  def reply(request, result) do
    send(Map.get(request, :reply_to, request.caller), {:relay_reply, request.ref, result})
    :ok
  end

  @spec flush_replies(reference()) :: :ok
  defp flush_replies(ref) do
    receive do
      {:relay_reply, ^ref, _} -> flush_replies(ref)
    after
      0 -> :ok
    end
  end

  @spec dispatch(pid(), map()) :: :ok
  def dispatch(stream, message) do
    send(stream, {:relay_dispatch, message})
    :ok
  end

  @impl true
  def init(state), do: {:ok, state}

  @impl true
  def handle_call({:register, host_id, pid}, _from, state) do
    nonce = Ash.UUID.generate()
    :ok = Marshall.Terminal.Directory.publish(host_id, nonce)
    register_stream(host_id, pid, nonce, state)
  end

  def handle_call({:register_authenticated, host_id, pid, session_id, epoch}, _from, state) do
    nonce = Ash.UUID.generate()

    case Marshall.Terminal.Directory.publish_authenticated(host_id, nonce, session_id, epoch) do
      :ok -> register_stream(host_id, pid, nonce, state)
      error -> {:reply, error, state}
    end
  end

  def handle_call({:stream_for, host_id}, _from, state) do
    if Marshall.Terminal.Directory.uri() do
      result =
        with {:ok, location} <- Marshall.Terminal.Directory.lookup(host_id) do
          case state[host_id] do
            %{nonce: nonce, pid: pid} when nonce == location.nonce -> {:ok, pid}
            _ -> {:remote, location}
          end
        end

      {:reply, result, state}
    else
      case :global.whereis_name(global_name(host_id)) do
        pid when is_pid(pid) -> {:reply, {:ok, pid}, state}
        :undefined -> {:reply, {:error, :stream_unavailable}, state}
      end
    end
  end

  def handle_call({:local_stream, host_id, nonce}, _from, state) do
    result =
      case state[host_id] do
        %{nonce: ^nonce, pid: pid} -> {:ok, pid}
        _ -> {:error, :stream_unavailable}
      end

    {:reply, result, state}
  end

  def handle_call({:renew, host_id, pid}, _from, state) do
    result =
      case state[host_id] do
        %{pid: ^pid, nonce: nonce} -> Marshall.Terminal.Directory.renew(host_id, nonce)
        _ -> {:error, :replaced}
      end

    {:reply, result, state}
  end

  @impl true
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    {:noreply, Map.reject(state, fn {_id, entry} -> entry.monitor == monitor end)}
  end

  def handle_info(_, state), do: {:noreply, state}

  @spec register_stream(String.t(), pid(), String.t(), map()) :: {:reply, :ok, map()}
  defp register_stream(host_id, pid, nonce, state) do
    name = global_name(host_id)

    case :global.whereis_name(name) do
      old when is_pid(old) and old != pid -> send(old, :relay_replaced)
      _ -> :ok
    end

    :yes = :global.re_register_name(name, pid)

    case state[host_id] do
      %{monitor: monitor, pid: old} ->
        Process.demonitor(monitor, [:flush])
        if old != pid, do: send(old, :relay_replaced)

      _ ->
        :ok
    end

    {:reply, :ok,
     Map.put(state, host_id, %{pid: pid, monitor: Process.monitor(pid), nonce: nonce})}
  end

  defp global_name(host_id), do: {__MODULE__, host_id}
end
