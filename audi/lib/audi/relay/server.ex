defmodule Audi.Relay.Server do
  @moduledoc "Bounded one-hop fleet listener; the destination always uses its local Lilly connector."
  use GenServer
  alias OverallsProtocol.IngressRelay

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)
  @spec port(GenServer.server()) :: :inet.port_number()
  def port(server), do: GenServer.call(server, :port)

  # @cc [owner:ghuntley,label:security] audi-relay-fleet-listener-only
  # The listener MUST bind one configured fleet /32 and admit only configured
  # WireGuard peer /32s. At most 128 workers may own sockets. A validated peer
  # capability MUST be consumed by Marshall before the local connector opens.
  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    address = Keyword.fetch!(options, :address)
    peers = Keyword.fetch!(options, :peers)

    with true <- IngressRelay.fleet_address?(address),
         true <-
           is_list(peers) and length(peers) in 1..254 and
             Enum.all?(peers, &IngressRelay.fleet_address?/1),
         {:ok, ip} <- :inet.parse_ipv4strict_address(String.to_charlist(address)),
         {:ok, listener} <-
           :gen_tcp.listen(
             Keyword.get(options, :port, 9445),
             [
               :binary,
               ip: ip,
               active: false,
               packet: 4,
               packet_size: IngressRelay.maximum(),
               backlog: 128,
               buffer: 65_536,
               send_timeout: 1000,
               send_timeout_close: true
             ]
           ) do
      owner = self()
      acceptor = spawn_link(fn -> accept(listener, owner) end)

      {:ok,
       %{
         listener: listener,
         acceptor: acceptor,
         workers: %{},
         peers: peers,
         client: Keyword.fetch!(options, :client),
         connector: Keyword.fetch!(options, :connector)
       }}
    else
      _ -> {:stop, :invalid_relay_configuration}
    end
  end

  @impl true
  def handle_call(:port, _, state) do
    {:ok, {_, port}} = :inet.sockname(state.listener)
    {:reply, port, state}
  end

  @impl true
  def handle_info({:accepted, acceptor}, %{acceptor: acceptor} = state) do
    if map_size(state.workers) < 128 do
      options = Map.take(state, [:peers, :client, :connector])

      {worker, monitor} =
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

      send(acceptor, {:handoff, worker})
      {:noreply, %{state | workers: Map.put(state.workers, monitor, worker)}}
    else
      send(acceptor, :reject)
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, monitor, :process, _, _}, state),
    do: {:noreply, %{state | workers: Map.delete(state.workers, monitor)}}

  def handle_info({:EXIT, acceptor, _}, %{acceptor: acceptor} = state),
    do: {:stop, :relay_listener_lost, state}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    :gen_tcp.close(state.listener)
    Process.exit(state.acceptor, :kill)
    Enum.each(state.workers, fn {_, worker} -> Process.exit(worker, :kill) end)
    :ok
  end

  @spec accept(:gen_tcp.socket(), pid()) :: :ok
  defp accept(listener, owner) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        send(owner, {:accepted, self()})

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

        accept(listener, owner)

      _ ->
        :ok
    end
  end

  @spec serve(:gen_tcp.socket(), map()) :: :ok
  defp serve(socket, options) do
    :logger.update_process_metadata(%{audi_private: true})
    {:ok, timer} = :timer.exit_after(30_000, self(), :kill)

    try do
      with {:ok, {peer, _}} <- :inet.peername(socket),
           address = List.to_string(:inet.ntoa(peer)),
           true <- address in options.peers,
           {:ok, bytes} <- :gen_tcp.recv(socket, 0, 1000),
           {:ok, preface} <- IngressRelay.decode(bytes),
           {:ok, grant} <-
             Audi.Control.Client.relay_exchange(options.client, :consume, preface, address),
           {:ok, _authority} <-
             Audi.Relay.Authority.start(options.client, preface, address, grant),
           {:ok, guest} <- Audi.StreamConnector.open(options.connector, grant) do
        try do
          with :ok <- :gen_tcp.send(socket, IngressRelay.ready()),
               :ok <- :inet.setopts(socket, packet: 0, packet_size: 0, active: :once),
               :ok <-
                 :inet.setopts(guest,
                   active: :once,
                   buffer: 65_536,
                   send_timeout: 1000,
                   send_timeout_close: true
                 ) do
            :timer.cancel(timer)
            relay(socket, guest)
          end
        after
          :gen_tcp.close(guest)
        end
      end
    after
      :timer.cancel(timer)
      :gen_tcp.close(socket)
    end

    :ok
  end

  # @cc [owner:ghuntley,label:security;reliability] audi-relay-bounded-no-replay
  # Both directions MUST use active-once and finite sends; a failed send or
  # transport close MUST terminate this stream without reconnecting or replay.
  @spec relay(:gen_tcp.socket(), :gen_tcp.socket()) :: :ok
  defp relay(client, guest) do
    receive do
      {:tcp, socket, bytes} when socket == client or socket == guest ->
        destination = if socket == client, do: guest, else: client

        if byte_size(bytes) <= 65_536 and :gen_tcp.send(destination, bytes) == :ok and
             :inet.setopts(socket, active: :once) == :ok, do: relay(client, guest), else: :ok

      {:tcp_closed, socket} when socket == client or socket == guest ->
        :ok

      {:tcp_error, socket, _} when socket == client or socket == guest ->
        :ok
    end
  end
end
