defmodule Lilly.Ingress.Server do
  @moduledoc "Bounded local ingress handoff. No listener or guest backend is enabled by default."
  use GenServer
  import Bitwise
  alias OverallsProtocol.IngressConnect

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    path = Keyword.fetch!(options, :path)
    uid = Keyword.fetch!(options, :audi_uid)
    host = Keyword.fetch!(options, :host_id)
    maximum = Keyword.get(options, :max_connections, 128)

    with true <-
           is_binary(path) and byte_size(path) in 1..107 and
             Path.type(path) == :absolute and Path.expand(path) == path and
             not String.contains?(path, <<0>>),
         true <- is_integer(uid) and uid in 0..4_294_967_294,
         true <- OverallsProtocol.uuid?(host),
         true <- is_integer(maximum) and maximum in 1..128,
         {:ok, %{uid: service_uid}} <- File.stat("/proc/self"),
         true <- trusted_directory?(Path.dirname(path), service_uid),
         {:ok, lock} <- Lilly.Ingress.SocketCustody.acquire(path),
         {:ok, socket} <-
           :gen_tcp.listen(0, [
             :binary,
             ifaddr: {:local, path},
             active: false,
             packet: 4,
             packet_size: IngressConnect.maximum(),
             backlog: 128,
             send_timeout: 1000,
             send_timeout_close: true
           ]) do
      case File.chmod(path, 0o660) do
        :ok ->
          {:ok, stat} = File.lstat(path)
          parent = self()
          acceptor = spawn_link(fn -> accept(socket, parent) end)

          {:ok,
           %{
             socket: socket,
             lock: lock,
             path: path,
             inode: stat.inode,
             uid: uid,
             host: host,
             maximum: maximum,
             backend: Keyword.get(options, :backend),
             acceptor: acceptor,
             workers: %{}
           }}

        _ ->
          :gen_tcp.close(socket)
          {:stop, :connector_unavailable}
      end
    else
      _ -> {:stop, :connector_unavailable}
    end
  end

  # @cc [owner:ghuntley,label:security] lilly-connector-owned-socket-directory
  # Binding and chmod MUST occur only beneath real directories owned by this
  # service or root, without group/other write access except root-owned sticky
  # directories. Existing paths MUST pass exclusive claimed-socket recovery;
  # unknown files or unclaimed sockets MUST NOT be removed or adopted.
  defp trusted_directory?(path, uid) do
    case File.lstat(path) do
      {:ok, %{type: :directory, uid: owner, mode: mode}} when owner == 0 or owner == uid ->
        (band(mode, 0o022) == 0 or (owner == 0 and band(mode, 0o1000) != 0)) and
          (path == "/" or trusted_directory?(Path.dirname(path), uid))

      _ ->
        false
    end
  end

  # @cc [owner:ghuntley,label:security] lilly-connector-bounded-local-admission
  # Each accepted socket MUST authenticate the configured Audi UID using Linux
  # peer credentials before reading the bounded request. Requests MUST bind this
  # host and a validated SSH/web/nested execution identity. At most 128 workers may exist;
  # setup, send operations and buffers MUST be bounded. Missing backend denies.
  @impl true
  # A lost hostd session ends this lease (ADR-0176 decision 4).
  def handle_info({:DOWN, ref, :process, _, _}, %{lock: %Lilly.Host.Lease{monitor: ref}} = state),
    do: {:stop, :connector_unavailable, state}

  def handle_info({:accepted, pid}, %{acceptor: pid} = state) do
    if map_size(state.workers) < state.maximum do
      options = Map.take(state, [:uid, :host, :backend])

      {worker, ref} =
        :erlang.spawn_opt(
          fn ->
            receive do
              {:socket, socket} -> serve(socket, options)
            after
              2000 -> :ok
            end
          end,
          [:link, :monitor]
        )

      send(pid, {:handoff, worker})
      {:noreply, %{state | workers: Map.put(state.workers, ref, worker)}}
    else
      send(pid, :reject)
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, state),
    do: {:noreply, %{state | workers: Map.delete(state.workers, ref)}}

  def handle_info({:EXIT, pid, _}, %{acceptor: pid} = state),
    do: {:stop, :connector_unavailable, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    Lilly.SupervisedStop.emit(:ingress, reason)
    :gen_tcp.close(state.socket)
    Process.exit(state.acceptor, :kill)
    Enum.each(state.workers, fn {_, pid} -> Process.exit(pid, :kill) end)

    if Lilly.Host.Lock.held?(state.lock) do
      case File.lstat(state.path) do
        {:ok, %{inode: inode, type: :other}} when inode == state.inode -> File.rm(state.path)
        _ -> :ok
      end
    end

    Lilly.Host.Lock.release(state.lock)

    :ok
  end

  @impl true
  def format_status(status),
    do:
      Map.new(status, fn
        {key, _} when key in [:state, :message, :reason] -> {key, :redacted}
        {:log, _} -> {:log, []}
        other -> other
      end)

  defp accept(listener, parent) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        send(parent, {:accepted, self()})

        receive do
          {:handoff, worker} ->
            case :gen_tcp.controlling_process(socket, worker) do
              :ok -> send(worker, {:socket, socket})
              _ -> :gen_tcp.close(socket)
            end

          :reject ->
            :gen_tcp.close(socket)
        after
          2000 -> :gen_tcp.close(socket)
        end

        accept(listener, parent)

      _ ->
        :ok
    end
  end

  defp serve(socket, options) do
    # The timer service kills this owner even if a backend blocks during setup.
    {:ok, timer} = :timer.exit_after(2000, self(), :kill)

    try do
      with :ok <- peer(socket, options.uid),
           {:ok, bytes} <- :gen_tcp.recv(socket, 0, 1000),
           {:ok, %{host_id: host} = binding} when host == options.host <-
             IngressConnect.decode(bytes) do
        :timer.cancel(timer)
        serve_bound(socket, options, binding)
      end
    rescue
      _ -> :ok
    catch
      _, _ -> :ok
    after
      :timer.cancel(timer)
      :gen_tcp.close(socket)
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] editor-bounded-cold-start
  # Only a validated editor binding may receive the bounded cold-start budget.
  # Its independent execution guardian MUST exist before worker preparation;
  # successful readiness MUST remove the setup timer before opaque relay.
  defp serve_bound(socket, options, binding) do
    {:ok, timer} =
      :timer.exit_after(if(binding.service == :editor, do: 22_000, else: 2000), self(), :kill)

    try do
      with {:ok, guest, guardian} when is_pid(guardian) <- open(options.backend, binding) do
        try do
          ref = Process.monitor(guardian)

          with true <- Process.alive?(guardian),
               :ok <-
                 :inet.setopts(guest,
                   active: false,
                   packet: 0,
                   send_timeout: 1000,
                   send_timeout_close: true
                 ),
               :ok <- :gen_tcp.send(socket, IngressConnect.ready()),
               :ok <- :inet.setopts(socket, packet: 0, packet_size: 0) do
            :timer.cancel(timer)
            relay(socket, guest, ref)
          end
        after
          :gen_tcp.close(guest)
        end
      end
    after
      :timer.cancel(timer)
    end
  end

  defp peer(socket, uid) do
    case :inet.getopts(socket, [{:raw, 1, 17, 12}]) do
      {:ok,
       [
         {:raw, 1, 17,
          <<_pid::native-signed-32, ^uid::native-unsigned-32, _gid::native-unsigned-32>>}
       ]} ->
        :ok

      _ ->
        :error
    end
  end

  # @cc [owner:ghuntley,label:assumption;security] lilly-connector-backend-fence
  # The operator-owned backend MUST resolve only current local durable execution
  # identity, return a passive guest socket owned by this worker, and supply a
  # guardian that dies when that execution loses authority. It MUST NOT derive
  # addresses or paths from unvalidated peer data. Production has no default backend.
  defp open({module, context}, binding), do: module.open(context, binding)
  defp open(_, _), do: {:error, :connector_unavailable}

  defp relay(client, guest, ref) do
    with :ok <- :inet.setopts(client, active: :once, buffer: 65_536),
         :ok <- :inet.setopts(guest, active: :once, buffer: 65_536) do
      pump(client, guest, ref)
    end
  end

  defp pump(client, guest, ref) do
    receive do
      {:tcp, socket, bytes} when socket == client or socket == guest ->
        target = if socket == client, do: guest, else: client

        with :ok <- :gen_tcp.send(target, bytes),
             :ok <- :inet.setopts(socket, active: :once),
             do: pump(client, guest, ref)

      {:DOWN, ^ref, :process, _, _} ->
        :ok

      {:tcp_closed, _} ->
        :ok

      {:tcp_error, _, _} ->
        :ok
    end
  end
end
