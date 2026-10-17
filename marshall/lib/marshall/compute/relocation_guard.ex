defmodule Marshall.Compute.RelocationGuard do
  @moduledoc "Transaction-scoped exclusion of ordinary lifecycle and maintenance during relocation."
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Ledger, Relocation, RelocationReadinessState, VirtualMachine}
  require Ash.Query

  # @cc [owner:ghuntley,label:concurrency] relocation-exclusion-shared-locks
  # Callers of vm_busy?/1 MUST hold the VM lock; callers of host_busy?/1 MUST hold
  # that host lock. Relocation creation/completion must hold both endpoint host
  # locks before its VM lock. Unfinished cleanup still excludes another relocation
  # and host maintenance, even after transfer slots have been released.
  @spec vm_busy?(String.t()) :: boolean()
  def vm_busy?(vm_id),
    do:
      Marshall.Compute.CloneGuard.vm_busy?(vm_id) or
        Marshall.Compute.Resize.busy?(vm_id) or
        present?(Relocation |> Ash.Query.filter(vm_id == ^vm_id and is_nil(finished_at)))

  # @cc [owner:ghuntley,label:recovery;concurrency] lifecycle-after-established-placement
  # Under the VM lock, start/stop and their ordinary recovery may proceed during
  # cleanup only on the exact restored source or ready committed destination.
  # Pending restoration/readiness MUST remain excluded. Delete enters its own
  # all-copy coordinator; ordinary outcome processing MUST retain its holds while
  # relocation is unfinished instead of archiving after just one copy disappears.
  @spec lifecycle_busy?(VirtualMachine.t(), atom()) :: boolean()
  def lifecycle_busy?(vm, kind) do
    Marshall.Compute.CloneGuard.lifecycle_busy?(vm.id, kind) or
      relocation_lifecycle_busy?(vm, kind)
  end

  defp relocation_lifecycle_busy?(vm, kind) do
    case Ledger.read!(Relocation, vm_id: vm.id, finished_at: [is_nil: true]) do
      [] ->
        false

      [relocation] when kind in [:start, :stop] ->
        restored =
          relocation.cancellation_requested_at != nil and
            relocation.source_restored_at != nil and relocation.committed_at == nil and
            vm.current_placement_id == relocation.source_placement_id and
            vm.execution_epoch == relocation.destination_epoch

        not (restored or RelocationReadinessState.ready?(relocation, vm))

      [_] ->
        true
    end
  end

  @spec host_busy?(String.t()) :: boolean()
  def host_busy?(host_id),
    do:
      Marshall.Compute.CloneGuard.host_busy?(host_id) or
        Marshall.Compute.Resize.host_busy?(host_id) or
        present?(
          Relocation
          |> Ash.Query.filter(
            is_nil(finished_at) and
              (source_host_id == ^host_id or destination_host_id == ^host_id)
          )
        )

  defp present?(query),
    do: query |> Ash.Query.limit(1) |> Ash.read!(actor: SystemActor.compute()) != []
end
