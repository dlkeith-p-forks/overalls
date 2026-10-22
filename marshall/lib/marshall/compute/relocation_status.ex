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

  # @cc [owner:ghuntley,label:security;observability] relocation-status-batched
  # For already authorized managers, the result for each VM id MUST equal
  # `latest/1` for that id: the same latest relocation and readiness request (by
  # inserted_at, then id, descending) and the same stop evidence. It reads each
  # record kind once for the whole batch and exposes only `describe/1` fields.
  @spec latest_many([String.t()]) :: %{String.t() => map() | nil}
  def latest_many([]), do: %{}

  def latest_many(vm_ids) do
    relocations = latest_by(Relocation, :vm_id, vm_ids)
    relocation_ids = relocations |> Map.values() |> Enum.map(& &1.id)
    readiness = latest_by(ReadinessRequest, :relocation_id, relocation_ids)

    operations =
      relocations
      |> Map.values()
      |> Enum.map(&(&1.source_stop_operation_id || &1.cancellation_stop_operation_id))
      |> Enum.reject(&is_nil/1)
      |> by_id(Operation)

    outcomes =
      operations
      |> Map.values()
      |> Enum.map(& &1.completion_outcome_id)
      |> Enum.reject(&is_nil/1)
      |> by_id(PhysicalOutcome)

    lookup = fn
      Operation, id -> List.wrap(Map.get(operations, id))
      PhysicalOutcome, id -> List.wrap(Map.get(outcomes, id))
    end

    Map.new(vm_ids, fn vm_id ->
      {vm_id,
       case Map.get(relocations, vm_id) do
         nil -> nil
         relocation -> build(relocation, Map.get(readiness, relocation.id), lookup)
       end}
    end)
  end

  @spec describe(Relocation.t()) :: map()
  def describe(relocation) do
    readiness = latest_record(ReadinessRequest, relocation_id: relocation.id)
    build(relocation, readiness, fn resource, id -> Ledger.read!(resource, id: id) end)
  end

  @spec build(
          Relocation.t(),
          ReadinessRequest.t() | nil,
          (module(), String.t() -> [Ash.Resource.Record.t()])
        ) :: map()
  defp build(relocation, readiness, lookup) do
    %{
      id: relocation.id,
      phase: relocation.phase,
      active: is_nil(relocation.finished_at),
      cancellable:
        is_nil(relocation.finished_at) and is_nil(relocation.committed_at) and
          is_nil(relocation.cancellation_requested_at) and
          is_nil(relocation.deletion_requested_at),
      retryable: false,
      downtime: downtime(relocation, readiness, lookup)
    }
  end

  # @cc [owner:ghuntley,label:observability] downtime-requires-stop-and-ready-evidence
  # Initially stopped/paused machines and missing quiescence evidence MUST show no
  # downtime, not zero. Measure from the pinned physical pause/stop outcome receipt
  # time to confirmed destination readiness or source restoration; handoff and
  # transfer bytes MUST NOT end the interval. An unfinished interval uses database
  # time. This is control-plane observed downtime, not measured guest availability.
  defp downtime(%{original_state: :stopped}, _, _), do: nil
  defp downtime(%{original_state: :paused}, _, _), do: nil
  defp downtime(%{deletion_requested_at: value}, _, _) when not is_nil(value), do: nil

  defp downtime(relocation, readiness, lookup) do
    stop_id = relocation.source_stop_operation_id || relocation.cancellation_stop_operation_id

    with id when not is_nil(id) <- stop_id,
         [%{status: :completed, kind: kind, completion_outcome_id: outcome_id}] <-
           lookup.(Operation, id),
         true <- kind in [:stop, :pause] and not is_nil(outcome_id),
         [%{observation: %{"state" => state, "compute_empty" => true}, inserted_at: stopped}] <-
           lookup.(PhysicalOutcome, outcome_id),
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

  # The newest record per key, ordered exactly as `latest_record/2` orders them.
  @spec latest_by(module(), atom(), [String.t()]) :: %{String.t() => Ash.Resource.Record.t()}
  defp latest_by(_resource, _field, []), do: %{}

  defp latest_by(resource, field, values) do
    resource
    |> Ash.Query.filter(^[{field, [in: values]}])
    |> Ash.read!(actor: SystemActor.compute())
    |> Enum.group_by(&Map.fetch!(&1, field))
    |> Map.new(fn {key, records} ->
      {key, Enum.max_by(records, &{DateTime.to_unix(&1.inserted_at, :microsecond), &1.id})}
    end)
  end

  @spec by_id([String.t()], module()) :: %{String.t() => Ash.Resource.Record.t()}
  defp by_id([], _resource), do: %{}

  defp by_id(ids, resource) do
    resource
    |> Ash.Query.filter(id in ^Enum.uniq(ids))
    |> Ash.read!(actor: SystemActor.compute())
    |> Map.new(&{&1.id, &1})
  end

  defp latest_record(resource, filter) do
    resource
    |> Ash.Query.filter(^filter)
    |> Ash.Query.sort(inserted_at: :desc, id: :desc)
    |> Ash.Query.limit(1)
    |> Ash.read_one!(actor: SystemActor.compute())
  end
end
