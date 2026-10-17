defmodule Brady.Listener do
  @moduledoc "Transparent IPv4 listener with bounded connection workers independent of guest lifetime."
  use GenServer
  require Brady.Events
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def child_spec(opts),
    do: %{
      id: {__MODULE__, Keyword.fetch!(opts, :scheme)},
      start: {__MODULE__, :start_link, [opts]}
    }

  # @cc [owner:ghuntley,label:security] brady-listener-transparent-only
  # Production listeners MUST request Linux IP_TRANSPARENT before binding.
  # Failure to obtain transparent socket privilege MUST fail startup, never
  # substitute a normal host listener. Concurrent workers MUST be bounded.
  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    options =
      [
        :binary,
        active: false,
        packet: 0,
        ip: {0, 0, 0, 0},
        reuseaddr: true,
        send_timeout: 15_000,
        send_timeout_close: true,
        buffer: 65_536
      ] ++ [{:raw, 0, 19, <<1::native-unsigned-32>>}]

    case :gen_tcp.listen(Keyword.fetch!(opts, :port), options) do
      {:ok, socket} ->
        server = self()
        acceptor = spawn_link(fn -> accept_loop(socket, server) end)

        {:ok,
         %{
           socket: socket,
           acceptor: acceptor,
           workers: %{},
           config: Keyword.fetch!(opts, :config),
           scheme: Keyword.fetch!(opts, :scheme),
           maximum: Keyword.get(opts, :max_connections, 256)
         }}

      _ ->
        Brady.Events.emit("brady.listener_failed", reason: :bind_failed)
        {:stop, :transparent_listener_unavailable}
    end
  end

  @impl true
  def format_status(status), do: Map.put(status, :state, :redacted)

  @impl true
  def handle_call(:worker, _, state) when map_size(state.workers) < state.maximum do
    scheme = state.scheme
    config = state.config

    {pid, ref} =
      spawn_monitor(fn ->
        receive do
          {:socket, socket} -> Brady.Connection.run(socket, scheme, config)
        after
          5_000 -> :ok
        end
      end)

    {:reply, {:ok, pid}, %{state | workers: Map.put(state.workers, ref, pid)}}
  end

  def handle_call(:worker, _, state) do
    Brady.Events.emit("brady.listener_overload", [])
    {:reply, :busy, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, state),
    do: {:noreply, %{state | workers: Map.delete(state.workers, ref)}}

  def handle_info({:EXIT, pid, _}, %{acceptor: pid} = state) do
    Brady.Events.emit("brady.listener_failed", reason: :acceptor_stopped)
    {:stop, :acceptor_stopped, state}
  end

  @impl true
  def terminate(_, state) do
    :gen_tcp.close(state.socket)
    Enum.each(state.workers, fn {_, pid} -> Process.exit(pid, :shutdown) end)
  end

  defp accept_loop(listener, server) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        case GenServer.call(server, :worker) do
          {:ok, pid} ->
            case :gen_tcp.controlling_process(socket, pid) do
              :ok ->
                send(pid, {:socket, socket})

              _ ->
                :gen_tcp.close(socket)
                Process.exit(pid, :shutdown)
            end

          _ ->
            :gen_tcp.close(socket)
        end

        accept_loop(listener, server)

      _ ->
        :ok
    end
  end
end
