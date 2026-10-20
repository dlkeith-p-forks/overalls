defmodule Marshall.Compute.Idle do
  @moduledoc "Fixed four-hour tool idle policy, enabled only at new thread-machine admission."
  alias Marshall.Compute.{Host, Ledger, Lifecycle, Operation, VirtualMachine, WakeRequest}
  alias Marshall.Agents.{Command, Root, Thread, Turn}

  @seconds 4 * 60 * 60
  @spec seconds() :: pos_integer()
  def seconds, do: @seconds

  # @cc [owner:ghuntley,label:product;recovery] idle-new-thread-machines-only
  # Only new thread-machine admission may enable this policy. Existing machines
  # MUST remain opted out. Enabling MUST be idempotent and initialize a full
  # four-hour window without rewriting activity on provisioning retries.
  @spec enable_locked!(VirtualMachine.t()) :: :ok
  def enable_locked!(vm) do
    unless vm.idle_suspend_enabled do
      Ledger.update!(vm, :idle_policy, %{
        idle_suspend_enabled: true,
        idle_activity_at: Ledger.now(),
        idle_revision: 1
      })
    end

    :ok
  end

  # @cc [owner:ghuntley,label:concurrency;product] idle-authorized-tool-clock
  # Caller MUST hold the VM lock. Accepted tool queue/start/completion and a new
  # wake window refresh the durable clock; heartbeats, model output, running
  # prompts and running network traffic MUST NOT. A clock rollback MUST never
  # move the deadline backwards.
  @spec touch_locked!(VirtualMachine.t()) :: :ok
  def touch_locked!(vm) do
    vm = Ledger.lock!(VirtualMachine, vm.id) || Ledger.rollback(:vm_deleted)

    if vm.idle_suspend_enabled do
      now = Ledger.now()

      activity =
        if vm.idle_activity_at && DateTime.compare(vm.idle_activity_at, now) == :gt,
          do: vm.idle_activity_at,
          else: now

      Ledger.update!(vm, :idle_policy, %{
        idle_activity_at: activity,
        idle_revision: vm.idle_revision + 1
      })
    end

    :ok
  end

  @spec due?(VirtualMachine.t(), DateTime.t()) :: boolean()
  def due?(%{idle_suspend_enabled: true, idle_activity_at: %DateTime{} = activity}, now),
    do: DateTime.diff(now, activity, :second) >= @seconds

  def due?(_, _), do: false

  # @cc [owner:ghuntley,label:concurrency;product] idle-pause-rechecks-under-lock
  # Host then VM locks MUST serialize the deadline decision with tool activity,
  # pinning and lifecycle. Only the owner's pin prevents automatic suspension;
  # queued/running turns and live tool commands defer it. No idle decision may
  # replace unresolved execution, resize, clone, relocation or wake work.
  @spec suspend(String.t()) :: {:ok, :paused | :deferred} | {:error, term()}
  def suspend(vm_id) do
    result =
      Ledger.transaction(fn ->
        case Ledger.read!(VirtualMachine, id: vm_id) do
          [] ->
            :deferred

          [candidate] ->
            host = Ledger.lock!(Host, candidate.host_id)
            vm = Ledger.lock!(VirtualMachine, vm_id)

            if vm && host && vm.host_id == host.id && eligible?(vm, Ledger.now()) do
              Lifecycle.pause_idle_locked!(vm, host)
              :paused
            else
              :deferred
            end
        end
      end)

    case result do
      {:ok, :paused} ->
        # A suspended machine cannot receive board notifications. Cleanup is
        # idempotent and deliberately happens after the lifecycle intent is
        # durable, so retries cannot resurrect stale entries.
        Marshall.MessageBoards.purge_for_state!(vm_id, :paused)
        result

      _ ->
        result
    end
  end

  @spec eligible?(VirtualMachine.t(), DateTime.t()) :: boolean()
  defp eligible?(vm, now) do
    due?(vm, now) and vm.desired_state == :running and vm.observed_state == :running and
      not Marshall.Access.Pins.owner_pinned?(vm) and
      not Marshall.Compute.RelocationGuard.vm_busy?(vm.id) and
      Ledger.read!(WakeRequest, vm_id: vm.id, finished_at: [is_nil: true]) == [] and
      Ledger.read!(Operation, vm_id: vm.id, status: [in: [:pending, :acknowledged]]) == [] and
      not active?(vm.id)
  end

  @spec active?(String.t()) :: boolean()
  def active?(vm_id) do
    roots = Ledger.read!(Root, vm_id: vm_id)

    Enum.any?(roots, fn root ->
      Ledger.read!(Command, root_id: root.id, status: [in: [:queued, :claimed, :started]]) != [] or
        Enum.any?(Ledger.read!(Thread, root_id: root.id), fn thread ->
          Ledger.read!(Turn, thread_id: thread.id, status: [in: [:queued, :running]]) != []
        end)
    end)
  end
end
