defmodule Ziggy.Lease do
  @moduledoc "Request fencing independent of blocked reads or downstream backpressure."
  use GenServer, restart: :temporary
  require Ziggy.Events

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)
  @spec stop(GenServer.server()) :: :ok
  def stop(server), do: GenServer.stop(server, :normal)

  @impl true
  def init(opts) do
    owner = Keyword.fetch!(opts, :owner)
    ttl = Keyword.get(opts, :ttl_ms, 30_000)
    renewal = Keyword.get(opts, :renewal_ms, 10_000)

    if is_integer(ttl) and ttl > 0 and ttl <= 30_000 and is_integer(renewal) and renewal > 0 and
         renewal < ttl and OverallsProtocol.uuid?(Keyword.fetch!(opts, :request_id)) do
      monitor = Process.monitor(owner)
      {:ok, timer} = :timer.exit_after(ttl, owner, :kill)
      Process.send_after(self(), :renew, renewal)

      {:ok,
       %{
         owner: owner,
         monitor: monitor,
         timer: timer,
         deadline: System.monotonic_time(:millisecond) + ttl,
         ttl: ttl,
         renewal: renewal,
         renew: Keyword.fetch!(opts, :renew),
         request_id: Keyword.fetch!(opts, :request_id),
         task: nil,
         renewal_started: nil,
         supervisor: Keyword.fetch!(opts, :tasks)
       }}
    else
      {:stop, :invalid_lease}
    end
  end

  # @cc [owner:ghuntley,label:security] lease-expiry-cancels-blocked-owner
  # Renewal work MUST NOT block expiry. Only a successful current-authority
  # response may extend a lease; revocation, errors and deadline expiry MUST
  # terminate the request owner, including when it is blocked on either peer.
  @impl true
  def handle_info(:renew, %{task: nil} = state) do
    task = Task.Supervisor.async_nolink(state.supervisor, state.renew)
    {:noreply, %{state | task: task, renewal_started: System.monotonic_time(:millisecond)}}
  end

  def handle_info({ref, :ok}, %{task: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    # The timer service targets the owner directly and survives this process.
    # A reply received after the previous deadline can never revive authority.
    now = System.monotonic_time(:millisecond)

    if now >= state.deadline do
      revoke(state, :expired)
    else
      remaining = max(0, state.renewal_started + state.ttl - now)
      {:ok, timer} = :timer.exit_after(remaining, state.owner, :kill)
      :timer.cancel(state.timer)
      Process.send_after(self(), :renew, state.renewal)
      {:noreply, %{state | timer: timer, deadline: now + remaining, task: nil}}
    end
  end

  def handle_info({ref, _}, %{task: %Task{ref: ref}} = state), do: revoke(state, :renewal_failed)

  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = state),
    do: {:stop, :normal, state}

  def handle_info({:DOWN, ref, :process, _, _}, %{task: %Task{ref: ref}} = state),
    do: revoke(state, :renewal_task_lost)

  def handle_info(:expire, state), do: revoke(state, :expired)
  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(reason, state) do
    if reason != :normal, do: Process.exit(state.owner, :kill)
    :timer.cancel(state.timer)
    if state.task, do: Task.shutdown(state.task, :brutal_kill)
    :ok
  end

  defp revoke(state, reason) do
    Ziggy.Events.emit("ziggy.lease_revoked", request_id: state.request_id, reason: reason)
    Process.exit(state.owner, :kill)
    {:stop, :normal, state}
  end
end
