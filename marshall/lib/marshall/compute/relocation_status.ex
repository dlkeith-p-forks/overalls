defmodule Marshall.Compute.RelocationStatus do
  @moduledoc "Bounded, non-authoritative relocation details for an already authorized manager."
  alias Marshall.Authorization.SystemActor

  alias Marshall.Compute.{
    Ledger,
    Relocation,
    ReadinessRequest,
    Operation,
    PhysicalOutcome
  }

  require Ash.Query

  # @cc [owner:ghuntley,label:security;observability] relocation-status-projection
  # The caller MUST first establish current VM manage permission. Read at most
  # one latest relocation, source request and readiness request plus the pinned
  # stop operation/outcome, if any. Expose only the
  # explicit UI fields, never host/placement IDs, keys, descriptors or permits.
  @spec latest(String.t()) :: map() | nil
  def latest(vm_id) do
    case latest_record(Relocation, vm_id: vm_id) do
      nil ->
        nil

      relocation ->
        describe(relocation)
    end
  end

  @spec describe(Relocation.t()) :: map()
  def describe(relocation) do
    readiness = latest_record(ReadinessRequest, relocation_id: relocation.id)

    %{
      id: relocation.id,
      phase: relocation.phase,
      active: is_nil(relocation.finished_at),
      cancellable:
        is_nil(relocation.finished_at) and is_nil(relocation.committed_at) and
          is_nil(relocation.cancellation_requested_at) and
          is_nil(relocation.deletion_requested_at),
      retryable: false,
      downtime: downtime(relocation, readiness)
    }
  end

  # @cc [owner:ghuntley,label:observability] downtime-requires-stop-and-ready-evidence
  # Initially stopped/paused machines and missing quiescence evidence MUST show no
  # downtime, not zero. Measure from the pinned physical pause/stop outcome receipt
  # time to confirmed destination readiness or source restoration; handoff and
  # transfer bytes MUST NOT end the interval. An unfinished interval uses database
  # time. This is control-plane observed downtime, not measured guest availability.
  defp downtime(%{original_state: :stopped}, _), do: nil
  defp downtime(%{original_state: :paused}, _), do: nil
  defp downtime(%{deletion_requested_at: value}, _) when not is_nil(value), do: nil

  defp downtime(relocation, readiness) do
    stop_id = relocation.source_stop_operation_id || relocation.cancellation_stop_operation_id

    with id when not is_nil(id) <- stop_id,
         [%{status: :completed, kind: kind, completion_outcome_id: outcome_id}] <-
           Ledger.read!(Operation, id: id),
         true <- kind in [:stop, :pause] and not is_nil(outcome_id),
         [%{observation: %{"state" => state, "compute_empty" => true}, inserted_at: stopped}] <-
           Ledger.read!(PhysicalOutcome, id: outcome_id),
         true <- state == if(kind == :pause, do: "paused", else: "stopped") do
      ready = if readiness != nil and readiness.status == :ready, do: readiness.completed_at
      ended = relocation.source_restored_at || ready

      %{
        seconds: max(0, DateTime.diff(ended || Ledger.now(), stopped, :second)),
        ongoing: is_nil(ended)
      }
    else
      _ -> nil
    end
  end

  defp latest_record(resource, filter) do
    resource
    |> Ash.Query.filter(^filter)
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(actor: SystemActor.compute())
  end
end
