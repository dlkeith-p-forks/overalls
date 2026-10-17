defmodule Marshall.Compute.ServiceLevels do
  @moduledoc "Deadline-bounded reliability measurements from committed physical and readiness evidence."
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Ledger, Operation, PhysicalOutcome, ServiceLevelAttempt}
  require Ash.Query

  @type physical :: %{state: :running | :stopped | :deleted | :failed, at: DateTime.t()}
  @type decision :: :pending | {:finished, boolean(), DateTime.t(), non_neg_integer()}
  @type service :: :marshall_ready | :lilly_physical | :porsche_physical
  @type operation_kind :: :provision | :start | :stop | :delete | :resize

  # @cc [owner:ghuntley,label:accounting;recovery] service-level-evidence-before-deadline
  # Success MUST match the admitted operation's terminal physical state and be
  # received by its immutable deadline. Creation-to-ready and SSH provision/start
  # additionally require a matching committed physical guest_ready fact by that
  # deadline. Unknown physical observations and daemon restarts MUST NOT become
  # physical failures. Missing evidence at the deadline is a measurement failure
  # only. Later evidence MUST NOT replace a finished measurement.
  @spec decide(
          service(),
          operation_kind(),
          DateTime.t(),
          DateTime.t(),
          physical() | nil,
          DateTime.t() | nil,
          DateTime.t()
        ) :: decision()
  def decide(service, kind, admitted, deadline, physical, ready_at, now) do
    expected = %{
      provision: :running,
      start: :running,
      stop: :stopped,
      delete: :deleted,
      resize: :stopped
    }

    needs_ready =
      service == :marshall_ready or
        (service == :porsche_physical and kind in [:provision, :start])

    cond do
      physical && physical.state == :failed && eligible?(physical.at, admitted, deadline) ->
        finished(false, physical.at, admitted)

      physical && physical.state == Map.fetch!(expected, kind) &&
        eligible?(physical.at, admitted, deadline) &&
          (not needs_ready or (ready_at && eligible?(ready_at, admitted, deadline))) ->
        at =
          if needs_ready && DateTime.compare(ready_at, physical.at) == :gt,
            do: ready_at,
            else: physical.at

        finished(true, at, admitted)

      DateTime.compare(now, deadline) != :lt ->
        finished(false, deadline, admitted)

      true ->
        :pending
    end
  end

  @spec reconcile(pos_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def reconcile(limit \\ 100) when limit in 1..100 do
    ServiceLevelAttempt
    |> Ash.Query.filter(status == :pending)
    |> Ash.Query.sort(checked_at: :asc, id: :asc)
    |> Ash.Query.limit(limit)
    |> Ash.read!(actor: SystemActor.compute())
    |> Enum.reduce_while({:ok, 0}, fn candidate, {:ok, count} ->
      result =
        Ledger.transaction(fn ->
          case ServiceLevelAttempt
               |> Ash.Query.filter(id == ^candidate.id and status == :pending)
               |> Ash.Query.lock("FOR UPDATE SKIP LOCKED")
               |> Ash.read!(actor: SystemActor.compute()) do
            [] -> 0
            [attempt] -> if(finish(attempt, Ledger.now()), do: 1, else: 0)
          end
        end)

      case result do
        {:ok, added} -> {:cont, {:ok, count + added}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # @cc [owner:ghuntley,label:security;concurrency] service-level-read-only-authority
  # Reconciliation MUST lock only measurement rows, read exact retained operation
  # bindings and persist terminal measurements inside one transaction. It MUST
  # NOT acquire host/VM locks, change operations or poll/refresh SSH receipts.
  @spec finish(ServiceLevelAttempt.t(), DateTime.t()) :: boolean()
  defp finish(attempt, now) do
    [operation] = Ledger.read!(Operation, id: attempt.operation_id)

    physical =
      PhysicalOutcome
      |> Ash.Query.filter(
        operation_id == ^operation.id and
          fragment("?->>'state'", observation) in ["running", "stopped", "deleted", "failed"]
      )
      |> Ash.Query.sort(sequence: :asc)
      |> Ash.Query.limit(1)
      |> Ash.read!(actor: SystemActor.compute())
      |> List.first()

    physical =
      with row when not is_nil(row) <- physical,
           {:ok, outcome} <- OverallsProtocol.Execution.outcome(row.observation),
           true <-
             outcome.id == row.id and outcome.operation_id == operation.id and
               outcome.vm_id == operation.vm_id and outcome.placement_id == operation.placement_id and
               outcome.execution_epoch == operation.execution_epoch and
               outcome.generation == operation.generation and
               row.host_id == operation.command_snapshot["host_id"],
           true <- outcome.state in [:running, :stopped, :deleted, :failed] do
        %{state: outcome.state, at: row.inserted_at}
      else
        _ -> nil
      end

    ready_at = ready_at(operation)

    case decide(
           attempt.service,
           operation.kind,
           attempt.admitted_at,
           attempt.deadline,
           physical,
           ready_at,
           now
         ) do
      :pending ->
        Ledger.update!(attempt, :check_pending, %{checked_at: now})
        false

      {:finished, success, completed_at, duration_us} ->
        finished =
          Ledger.update!(attempt, :finish, %{
            success: success,
            completed_at: completed_at,
            duration_us: duration_us
          })

        Marshall.Compute.ServiceLevelTotals.add!(finished)
        true
    end
  end

  @spec ready_at(Operation.t()) :: DateTime.t() | nil
  defp ready_at(%{kind: kind} = operation) when kind in [:provision, :start] do
    host_id = operation.command_snapshot["host_id"]

    PhysicalOutcome
    |> Ash.Query.filter(
      operation_id == ^operation.id and vm_id == ^operation.vm_id and
        placement_id == ^operation.placement_id and execution_epoch == ^operation.execution_epoch and
        generation == ^operation.generation and host_id == ^host_id and
        fragment("?->>'guest_ready'", observation) == "true" and
        fragment("?->>'state'", observation) == "running" and
        fragment("?->>'id'", observation) == fragment("?::text", id) and
        fragment("?->>'operation_id'", observation) == ^operation.id and
        fragment("?->>'vm_id'", observation) == ^operation.vm_id and
        fragment("?->>'placement_id'", observation) == ^operation.placement_id and
        fragment("?->>'execution_epoch'", observation) ==
          ^Integer.to_string(operation.execution_epoch) and
        fragment("?->>'generation'", observation) == ^Integer.to_string(operation.generation)
    )
    |> Ash.Query.sort(inserted_at: :asc, id: :asc)
    |> Ash.Query.limit(1)
    |> Ash.read!(actor: SystemActor.compute())
    |> Enum.find_value(fn row ->
      with {:ok, outcome} <- OverallsProtocol.Execution.outcome(row.observation),
           true <- Map.get(outcome, :guest_ready) == true and outcome.state == :running,
           true <-
             outcome.id == row.id and outcome.operation_id == operation.id and
               outcome.vm_id == operation.vm_id and outcome.placement_id == operation.placement_id and
               outcome.execution_epoch == operation.execution_epoch and
               outcome.generation == operation.generation and
               row.host_id == operation.command_snapshot["host_id"],
           do: row.inserted_at,
           else: (_ -> nil)
    end)
  end

  defp ready_at(_), do: nil

  @spec eligible?(DateTime.t(), DateTime.t(), DateTime.t()) :: boolean()
  defp eligible?(at, admitted, deadline),
    do: DateTime.compare(at, admitted) != :lt and DateTime.compare(at, deadline) != :gt

  @spec finished(boolean(), DateTime.t(), DateTime.t()) :: decision()
  defp finished(success, at, admitted),
    do: {:finished, success, at, DateTime.diff(at, admitted, :microsecond)}
end
