defmodule Marshall.Compute.RelocationDeletion do
  @moduledoc "Logical Delete supersedes relocation while retaining all copy obligations."
  alias Marshall.Compute.{
    Ledger,
    NetworkAddress,
    Operation,
    PhysicalOutcome,
    Relocation,
    RelocationCleanup,
    Reservation,
    VirtualMachine
  }

  # @cc [owner:ghuntley,label:concurrency;security] deletion-endpoint-locks-before-intent
  # Under the VM lock, active_locked!/2 MUST reject an unfinished relocation whose
  # endpoint locks were not acquired before that VM lock. A race with admission
  # or handoff must retry without mutating lifecycle intent or reservations.
  @spec active_locked!(VirtualMachine.t(), [String.t()]) :: Relocation.t() | nil
  def active_locked!(vm, hosts) do
    case Ledger.read!(Relocation, vm_id: vm.id, finished_at: [is_nil: true]) do
      [] ->
        nil

      [relocation] ->
        unless relocation.source_host_id in hosts and relocation.destination_host_id in hosts,
          do: Ledger.rollback(:placement_changed)

        relocation
    end
  end

  # @cc [owner:ghuntley,label:security;recovery] deletion-supersedes-without-restoration
  # The authorized lifecycle transaction holds both endpoint locks then the VM
  # lock and MUST atomically bind its user Delete operation to this obligation.
  # Before handoff it records cancellation to fence further transfer offers;
  # deletion MUST take precedence over source restoration and never enqueue a start.
  # After handoff it MUST preserve destination authority and old-source cleanup.
  # Pending destination retries MUST be superseded before they can enqueue activation.
  @spec request_locked!(Relocation.t(), Operation.t(), Marshall.Accounts.User.t()) ::
          Relocation.t()
  def request_locked!(relocation, operation, actor) do
    unless operation.kind == :delete and operation.initiator == :user and
             operation.vm_id == relocation.vm_id and operation.requested_by_id == actor.id and
             relocation.deletion_requested_at == nil,
           do: Ledger.rollback(:invalid_delete_intent)

    for retry <-
          Ledger.read!(Marshall.Compute.RelocationRetry,
            relocation_id: relocation.id,
            finished_at: [is_nil: true]
          ),
        do: Ledger.update!(retry, :supersede, %{finished_at: Ledger.now()})

    for readiness <-
          Ledger.read!(Marshall.Compute.ReadinessRequest,
            relocation_id: relocation.id,
            status: :pending
          ),
        do:
          Ledger.update!(readiness, :fail, %{
            failure_reason: :activation_changed,
            completed_at: Ledger.now()
          })

    relocation =
      if relocation.committed_at == nil and relocation.cancellation_requested_at == nil do
        Ledger.update!(relocation, :request_cancellation, %{
          cancellation_requested_at: Ledger.now(),
          cancellation_requested_by_id: actor.id
        })
      else
        relocation
      end

    Ledger.update!(relocation, :request_deletion, %{
      deletion_requested_at: Ledger.now(),
      deletion_operation_id: operation.id
    })
  end

  # @cc [owner:ghuntley,label:capacity;recovery] deletion-all-copies-before-archive
  # Under both endpoint host locks then the VM lock, release each copy only after
  # its physical deletion evidence. The current copy requires its exact user
  # Delete outcome; an uncommitted destination requires its fenced cleanup receipt.
  # A committed old source keeps its existing cleanup/key-retirement obligations,
  # even when readiness failed. Both transfer revocations and every placement's
  # reclaimed commitments MUST precede relocation completion, address release and
  # VM archival. Unknown outcomes and unavailable hosts retain durable obligations.
  @spec advance_locked!(Relocation.t(), VirtualMachine.t()) :: atom()
  def advance_locked!(relocation, vm) do
    with true <- vm != nil and vm.archived_at == nil and vm.desired_state == :deleted,
         [operation] <- Ledger.read!(Operation, id: relocation.deletion_operation_id),
         true <-
           operation.vm_id == vm.id and operation.kind == :delete and
             operation.initiator == :user and operation.placement_id == vm.current_placement_id and
             operation.execution_epoch == vm.execution_epoch and
             operation.generation == vm.generation do
      if relocation.committed_at != nil do
        RelocationCleanup.advance_locked!(relocation, vm)
      else
        if relocation.destination_cleaned_at != nil and relocation.destination_revoked_at != nil,
          do: release!(relocation.destination_placement_id)
      end

      deleted = deleted?(operation)
      if deleted, do: release!(operation.placement_id)

      if deleted and relocation.source_revoked_at != nil and
           relocation.destination_revoked_at != nil and
           Enum.all?(Ledger.read!(Reservation, vm_id: vm.id), &reclaimed?/1) do
        Ledger.update!(relocation, :finish_deletion, %{finished_at: Ledger.now()})

        for address <- Ledger.read!(NetworkAddress, vm_id: vm.id),
            do: Ledger.archive!(address, :release)

        Marshall.Access.Pins.remove_for_vm!(vm.id)
        Ledger.archive!(vm, :archive)
        :deleted
      else
        :deleting
      end
    else
      _ -> :deleting
    end
  end

  defp release!(placement) do
    [reservation] = Ledger.read!(Reservation, placement_id: placement)
    unless reclaimed?(reservation), do: Ledger.update!(reservation, :release_all, %{})
  end

  defp reclaimed?(reservation),
    do:
      not reservation.compute_held and not reservation.disk_held and
        reservation.temporary_disk_bytes == 0

  defp deleted?(%{status: :completed, completion_outcome_id: id} = operation)
       when not is_nil(id) do
    with [outcome] <- Ledger.read!(PhysicalOutcome, id: id),
         {:ok, physical} <- OverallsProtocol.Execution.outcome(outcome.observation),
         true <-
           physical.operation_id == operation.id and physical.vm_id == operation.vm_id and
             physical.placement_id == operation.placement_id and
             physical.execution_epoch == operation.execution_epoch and
             physical.generation == operation.generation and physical.state == :deleted and
             physical.compute_empty and not physical.disk_present and physical.cleanup_complete,
         do: true,
         else: (_ -> false)
  end

  defp deleted?(_), do: false
end
