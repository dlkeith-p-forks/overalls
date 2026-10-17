defmodule Audi.DNS.Server do
  @moduledoc "Audi's bounded authoritative DNS listeners on UDP and TCP."
  use GenServer
  alias Audi.DNS.Authority
  require Audi.Events

  def start_link(options),
    do: GenServer.start_link(__MODULE__, options, Keyword.take(options, [:name]))

  def port(server), do: GenServer.call(server, :port)

  @spec ready?(GenServer.server()) :: boolean()
  def ready?(server) do
    GenServer.call(server, :ready, 100)
  catch
    :exit, _ -> false
  end

  @impl true
  def init(options) do
    Process.flag(:trap_exit, true)
    ip = Keyword.get(options, :ip, {127, 0, 0, 1})
    port = Keyword.get(options, :port, 0)

    authority =
      {Keyword.get(options, :authority_module, Authority), Keyword.fetch!(options, :authority)}

    with {:ok, tcp} <-
           :gen_tcp.listen(port, [
             :binary,
             ip: ip,
             active: false,
             packet: 2,
             packet_size: 65_535,
             reuseaddr: true,
             backlog: 128,
             send_timeout: 5000,
             send_timeout_close: true
           ]),
         {:ok, {_, bound_port}} <- :inet.sockname(tcp) do
      case :gen_udp.open(bound_port, [:binary, ip: ip, active: :once, recbuf: 262_144]) do
        {:ok, udp} ->
          parent = self()
          acceptor = spawn_link(fn -> accept(tcp, parent) end)

          {:ok,
           %{
             tcp: tcp,
             udp: udp,
             port: bound_port,
             authority: authority,
             acceptor: acceptor,
             workers: %{},
             maximum: Keyword.get(options, :max_connections, 128)
           }}

        {:error, reason} ->
          :gen_tcp.close(tcp)
          Audi.Events.emit("audi.dns_listener_failed", reason: reason)
          {:stop, reason}
      end
    else
      {:error, reason} ->
        Audi.Events.emit("audi.dns_listener_failed", reason: reason)
        {:stop, reason}
    end
  end

  @impl true
  def handle_call(:port, _, state), do: {:reply, state.port, state}

  def handle_call(:ready, _, state) do
    ready =
      match?({:ok, _}, :inet.sockname(state.tcp)) and
        match?({:ok, _}, :inet.sockname(state.udp)) and Process.alive?(state.acceptor)

    {:reply, ready, state}
  end

  # @cc [owner:ghuntley,label:security] dns-listener-bounds
  # UDP uses active-once delivery. TCP workers MUST be admission-bounded, linked
  # to the service and subject to read/write deadlines. Malformed traffic MUST
  # NOT log raw peer data or grant recursive DNS service.
  @impl true
  def handle_info({:udp, socket, ip, port, packet}, %{udp: socket} = state) do
    started = System.monotonic_time(:microsecond)
    {response, outcome, ticket} = answer_with_outcome(packet, state.authority, :udp)

    delivery =
      case response do
        :drop -> :excluded
        response -> :gen_udp.send(socket, ip, port, response)
      end

    record_outcome(outcome, delivery, started, ticket)

    :inet.setopts(socket, active: :once)
    {:noreply, state}
  end

  def handle_info({:accepted, acceptor}, %{acceptor: acceptor} = state) do
    if map_size(state.workers) < state.maximum do
      authority = state.authority

      {worker, ref} =
        :erlang.spawn_opt(
          fn ->
            receive do
              {:socket, socket} -> tcp_loop(socket, authority, 256)
            after
              5000 -> :ok
            end
          end,
          [:link, :monitor]
        )

      send(acceptor, {:handoff, worker})
      {:noreply, %{state | workers: Map.put(state.workers, ref, worker)}}
    else
      Audi.Events.emit("audi.dns_overload", [])
      send(acceptor, :reject)
      {:noreply, state}
    end
  end

  def handle_info({:DOWN, ref, :process, _, _}, state),
    do: {:noreply, %{state | workers: Map.delete(state.workers, ref)}}

  def handle_info({:EXIT, pid, _}, %{acceptor: pid} = state) do
    Audi.Events.emit("audi.dns_listener_failed", reason: :acceptor_stopped)
    {:stop, :acceptor_stopped, state}
  end

  def handle_info({:EXIT, _, _}, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    :gen_tcp.close(state.tcp)
    :gen_udp.close(state.udp)
    Process.exit(state.acceptor, :shutdown)
    Enum.each(state.workers, fn {_, pid} -> Process.exit(pid, :shutdown) end)
    :ok
  end

  defp accept(listener, parent) do
    case :gen_tcp.accept(listener) do
      {:ok, socket} ->
        send(parent, {:accepted, self()})

        receive do
          {:handoff, worker} ->
            case :gen_tcp.controlling_process(socket, worker) do
              :ok -> send(worker, {:socket, socket})
              {:error, _} -> :gen_tcp.close(socket)
            end

          :reject ->
            :gen_tcp.close(socket)
        after
          5000 -> :gen_tcp.close(socket)
        end

        accept(listener, parent)

      {:error, _} ->
        :ok
    end
  end

  defp answer_with_outcome(packet, {Authority, authority}, transport) do
    ticket =
      if Authority.eligible?(packet, authority),
        do: Overalls.RequestAccounting.Producer.admit(Audi.RequestRecorder),
        else: :unrecorded

    {response, outcome} = Authority.answer_with_outcome(packet, authority, transport)
    {response, outcome, ticket}
  end

  defp answer_with_outcome(packet, {module, authority}, transport),
    do: {module.answer(packet, authority, transport), :exclude, :unrecorded}

  # @cc [owner:ghuntley,label:reliability] dns-delivered-candidate-outcome
  # Only qualified public DNS questions MAY enter the candidate counter, once
  # after a reply is produced. A socket send failure MUST count as failure.
  # Private DNS and deliberately dropped packets MUST remain excluded.
  defp record_outcome(:exclude, _delivery, _started, ticket),
    do: Overalls.RequestAccounting.Producer.complete(Audi.RequestRecorder, ticket, :exclude, 0)

  defp record_outcome(outcome, delivery, started, ticket) do
    duration_us = max(0, System.monotonic_time(:microsecond) - started)

    Overalls.RequestAccounting.Producer.complete(
      Audi.RequestRecorder,
      ticket,
      if(outcome == :success and delivery == :ok, do: :success, else: :failure),
      duration_us
    )

    Audi.SLO.record_outcome(outcome == :success and delivery == :ok, duration_us)
  end

  defp tcp_loop(socket, _, 0), do: :gen_tcp.close(socket)

  defp tcp_loop(socket, authority, remaining) do
    case :gen_tcp.recv(socket, 0, 5000) do
      {:ok, packet} ->
        started = System.monotonic_time(:microsecond)
        {response, outcome, ticket} = answer_with_outcome(packet, authority, :tcp)

        case response do
          response when is_binary(response) ->
            delivery = :gen_tcp.send(socket, response)
            record_outcome(outcome, delivery, started, ticket)

            if delivery == :ok,
              do: tcp_loop(socket, authority, remaining - 1),
              else: :gen_tcp.close(socket)

          :drop ->
            record_outcome(:exclude, :excluded, started, ticket)
            :gen_tcp.close(socket)
        end

      _ ->
        :gen_tcp.close(socket)
    end
  end
end
