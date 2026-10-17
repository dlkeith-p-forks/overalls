defmodule Audi.Authority.StreamGuard do
  @moduledoc "Fail-closed lifetime guard for one process owning guest stream resources."
  use GenServer, restart: :temporary
  alias Audi.Authority.Lease
  require Audi.Events

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(options), do: GenServer.start_link(__MODULE__, options)

  # @cc [owner:ghuntley,label:security] audi-stream-resource-ownership
  # The owner MUST be a dedicated stream process that owns its sockets/channels;
  # killing it MUST close all guest resources. Start only after authenticated
  # admission, before forwarding bytes. Renewal work MUST run outside this guard.
  # Guard failure, denial, binding change or expiry MUST kill the owner, even if
  # it traps exits. This process MUST NOT be restarted with an old grant.
  @impl true
  def init(options) do
    owner = Keyword.fetch!(options, :owner)

    with true <- is_pid(owner) and owner != self() and node(owner) == node(),
         {:ok, lease} <-
           Lease.new(
             Keyword.fetch!(options, :binding),
             Keyword.fetch!(options, :requested_at),
             Keyword.fetch!(options, :ttl),
             now()
           ) do
      guard = self()
      monitor = Process.monitor(owner)
      token = make_ref()
      watchdog = spawn(fn -> watch(guard, owner, token, lease.expires_at) end)

      {:ok,
       arm(%{
         owner: owner,
         monitor: monitor,
         lease: lease,
         timer: nil,
         watchdog: watchdog,
         token: token,
         fenced: false
       })}
    else
      _ -> {:stop, :invalid_grant}
    end
  end

  @spec renew(GenServer.server(), map(), integer(), integer()) :: :ok | {:error, atom()}
  def renew(server, binding, requested_at, ttl) do
    GenServer.call(server, {:renew, binding, requested_at, ttl}, 1000)
  catch
    :exit, _ -> {:error, :closed}
  end

  @spec revoke(GenServer.server()) :: :ok
  def revoke(server) do
    GenServer.call(server, :revoke, 1000)
  catch
    :exit, _ -> :ok
  end

  @impl true
  def handle_call({:renew, binding, started, ttl}, _, state) do
    case Lease.renew(state.lease, binding, started, ttl, now()) do
      {:ok, lease} ->
        {:reply, :ok, arm(%{state | lease: lease})}

      {:error, :stale} = error ->
        {:reply, error, state}

      {:error, reason} ->
        {:stop, :normal, {:error, reason}, close(state, reason)}
    end
  end

  def handle_call(:revoke, _, state), do: {:stop, :normal, :ok, close(state, :revoked)}

  @impl true
  def handle_info({:expire, deadline}, %{lease: %{expires_at: deadline}} = state) do
    if Lease.active?(state.lease, now()),
      do: {:noreply, arm(state)},
      else: {:stop, :normal, close(state, :expired)}
  end

  def handle_info({:DOWN, ref, :process, _, _}, %{monitor: ref} = state),
    do: {:stop, :normal, %{state | fenced: true}}

  def handle_info(_, state), do: {:noreply, state}

  @impl true
  def terminate(_, state) do
    close(state, :guard_closed)
    :ok
  end

  defp close(state, reason) do
    unless state.fenced do
      binding = execution(state.lease.binding)
      emit_fenced(binding, reason)
    end

    Process.exit(state.owner, :kill)
    if state.timer, do: Process.cancel_timer(state.timer)
    %{state | fenced: true}
  end

  defp execution(%{execution: binding}) when is_map(binding), do: binding
  defp execution(binding) when is_map(binding), do: binding

  defp emit_fenced(binding, reason) do
    Audi.Events.emit("audi.stream_fenced",
      host_id: binding.host_id,
      vm_id: binding.vm_id,
      reason: reason
    )
  end

  defp arm(state) do
    if state.timer, do: Process.cancel_timer(state.timer)
    delay = max(state.lease.expires_at - now(), 0)
    send(state.watchdog, {:renew, state.token, state.lease.expires_at})
    timer = Process.send_after(self(), {:expire, state.lease.expires_at}, delay)
    %{state | timer: timer}
  end

  # An unlinked watchdog also closes the owner when the guard is killed or
  # suspended before its timer/terminate callback runs. Either monitored process
  # ending releases the watchdog. Deadline checks precede queued renewals.
  defp watch(guard, owner, token, deadline) do
    guard_ref = Process.monitor(guard)
    owner_ref = Process.monitor(owner)
    watch_deadline(owner, guard_ref, owner_ref, token, deadline)
  end

  defp watch_deadline(owner, guard_ref, owner_ref, token, deadline) do
    remaining = deadline - now()

    if remaining <= 0 do
      Process.exit(owner, :kill)
    else
      receive do
        {:DOWN, ^guard_ref, :process, _, _} ->
          Process.exit(owner, :kill)

        {:DOWN, ^owner_ref, :process, ^owner, _} ->
          :ok

        {:renew, ^token, next_deadline} ->
          if now() < deadline,
            do: watch_deadline(owner, guard_ref, owner_ref, token, next_deadline),
            else: Process.exit(owner, :kill)
      after
        remaining -> Process.exit(owner, :kill)
      end
    end
  end

  defp now, do: System.monotonic_time(:millisecond)
end
