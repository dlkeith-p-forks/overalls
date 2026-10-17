defmodule Marshall.Compute.WorkflowServiceLevels do
  @moduledoc "Durable clone, relocation and control-command measurements from retained terminal evidence."
  require Ash.Query
  alias Marshall.Authorization.SystemActor

  alias Marshall.Compute.{
    CloneRequest,
    Ledger,
    LifecycleAudit,
    LifecycleEvent,
    Operation,
    PhysicalOutcome,
    Relocation,
    RelocationRetry,
    ServiceLevelTotals,
    WorkflowServiceLevelAttempt
  }

  @type service :: :porsche_clone | :porsche_relocate | :porsche_retry | :porsche_cancel
  @type outcome :: :succeeded | :failed | :cancelled | :superseded
  @type evidence :: %{outcome: outcome(), at: DateTime.t()}
  @type decision ::
          :pending
          | {:finished, boolean(), DateTime.t(), non_neg_integer()}
          | {:excluded, :cancelled | :superseded, DateTime.t(), non_neg_integer()}

  # @cc [owner:ghuntley,label:accounting;durability] workflow-receipt-admission
  # An accepted new workflow receipt MUST admit once in its mutation transaction,
  # using the database clock captured before the mutation. Replay MUST NOT reset
  # admission, deadlines or clone sequence. Old unmeasured receipts stay excluded.
  # An immediate terminal domain result MAY finish in this admission transaction.
  @spec admit!(Marshall.SSH.Request.t()) :: :ok
  def admit!(
        %{status: :accepted, operation_id: nil, measurement_started_at: %DateTime{}} = request
      ) do
    case workflow_binding(request) do
      nil ->
        :ok

      {type, row} ->
        case Ledger.read!(WorkflowServiceLevelAttempt, request_id: request.id) do
          [] ->
            service = service(request.command["command"])
            ServiceLevelTotals.ensure!(service)
            expected = if service == :porsche_cancel, do: :cancelled, else: :succeeded

            attempt =
              Ledger.create!(WorkflowServiceLevelAttempt, :admit, %{
                request_id: request.id,
                service: service,
                workflow_type: type,
                workflow_id: row.id,
                sequence: if(type == :clone, do: row.sequence),
                expected_outcome: expected,
                admitted_at: request.measurement_started_at,
                deadline: DateTime.add(request.measurement_started_at, 600, :second)
              })

            # A synchronous/no-op cancellation may already be terminal. This
            # trusted domain result was read inside the admitted mutation;
            # subsequent scans never infer completion from a user receipt.
            case LifecycleAudit.measurement_outcome(row) do
              nil ->
                :ok

              outcome ->
                at = Ledger.now()

                persist!(
                  attempt,
                  decide(
                    expected,
                    attempt.admitted_at,
                    attempt.deadline,
                    %{outcome: outcome, at: at},
                    at
                  )
                )

                :ok
            end

          _ ->
            :ok
        end
    end
  end

  def admit!(_), do: :ok

  @spec workflow_binding(Marshall.SSH.Request.t()) ::
          {:clone, CloneRequest.t()}
          | {:relocation, Relocation.t()}
          | {:relocation_retry, RelocationRetry.t()}
          | nil
  defp workflow_binding(%{clone_request_id: id}) when not is_nil(id),
    do: {:clone, hd(Ledger.read!(CloneRequest, id: id))}

  defp workflow_binding(%{relocation_retry_id: id}) when not is_nil(id),
    do: {:relocation_retry, hd(Ledger.read!(RelocationRetry, id: id))}

  defp workflow_binding(%{relocation_id: id}) when not is_nil(id),
    do: {:relocation, hd(Ledger.read!(Relocation, id: id))}

  defp workflow_binding(_), do: nil

  @spec service(String.t()) :: service()
  defp service("clone"), do: :porsche_clone
  defp service("relocate"), do: :porsche_relocate
  defp service("request retry"), do: :porsche_retry
  defp service("request cancel"), do: :porsche_cancel

  # @cc [owner:ghuntley,label:accounting;recovery] workflow-evidence-window
  # Only matching terminal evidence received within the immutable admission and
  # deadline window may finish successfully. Cancellation of the original intent
  # and supersession MUST remain terminal exclusions, without changing totals.
  # Other wrong dispositions, failures or missing proof at deadline MUST fail.
  @spec decide(outcome(), DateTime.t(), DateTime.t(), evidence() | nil, DateTime.t()) ::
          decision()
  def decide(expected, admitted, deadline, evidence, now) do
    cond do
      evidence && DateTime.compare(evidence.at, admitted) != :lt &&
        DateTime.compare(evidence.at, deadline) != :gt &&
          DateTime.compare(evidence.at, now) != :gt ->
        duration = DateTime.diff(evidence.at, admitted, :microsecond)

        case {expected, evidence.outcome} do
          {_, :superseded} -> {:excluded, :superseded, evidence.at, duration}
          {:succeeded, :cancelled} -> {:excluded, :cancelled, evidence.at, duration}
          _ -> {:finished, evidence.outcome == expected, evidence.at, duration}
        end

      DateTime.compare(now, deadline) != :lt ->
        {:finished, false, deadline, DateTime.diff(deadline, admitted, :microsecond)}

      true ->
        :pending
    end
  end

  @spec reconcile(pos_integer()) :: {:ok, non_neg_integer()} | {:error, term()}
  def reconcile(limit \\ 100) when limit in 1..100 do
    WorkflowServiceLevelAttempt
    |> Ash.Query.filter(status == :pending)
    |> Ash.Query.sort(checked_at: :asc, id: :asc)
    |> Ash.Query.limit(limit)
    |> Ash.read!(actor: SystemActor.compute())
    |> Enum.reduce_while({:ok, 0}, fn candidate, {:ok, count} ->
      result =
        Ledger.transaction(fn ->
          case WorkflowServiceLevelAttempt
               |> Ash.Query.filter(id == ^candidate.id and status == :pending)
               |> Ash.Query.lock("FOR UPDATE SKIP LOCKED")
               |> Ash.read!(actor: SystemActor.compute()) do
            [] ->
              0

            [attempt] ->
              persist!(
                attempt,
                decide(
                  attempt.expected_outcome,
                  attempt.admitted_at,
                  attempt.deadline,
                  evidence(attempt),
                  Ledger.now()
                )
              )
          end
        end)

      case result do
        {:ok, added} -> {:cont, {:ok, count + added}}
        {:error, reason} -> {:halt, {:error, reason}}
      end
    end)
  end

  # @cc [owner:ghuntley,label:security;accounting] workflow-retained-authority
  # Scans MUST lock measurement rows only and never refresh SSH receipts or
  # acquire execution locks. Clone evidence MUST match its admitted sequence.
  # Retry activation alone MUST NOT succeed: its immutable start operation needs
  # exact physical running evidence and matching committed readiness.
  @spec evidence(WorkflowServiceLevelAttempt.t()) :: evidence() | nil
  defp evidence(%{workflow_type: :relocation_retry} = attempt) do
    terminal = terminal(attempt, "RelocationRetry", attempt.workflow_id, nil)

    if terminal do
      terminal
    else
      [retry] = Ledger.read!(RelocationRetry, id: attempt.workflow_id)
      if retry.start_operation_id, do: activation_evidence(attempt, retry)
    end
  end

  defp evidence(attempt) do
    type = if attempt.workflow_type == :clone, do: "CloneRequest", else: "Relocation"
    terminal(attempt, type, attempt.workflow_id, attempt.sequence)
  end

  @type readiness_fence :: %{generation: pos_integer(), workflow_id: String.t()}
  @spec terminal(
          WorkflowServiceLevelAttempt.t(),
          String.t(),
          String.t(),
          pos_integer() | nil,
          readiness_fence() | nil
        ) ::
          evidence() | nil
  defp terminal(attempt, type, id, sequence, fence \\ nil) do
    query =
      LifecycleEvent
      |> Ash.Query.filter(
        resource_type == ^type and resource_id == ^id and
          not is_nil(measurement_outcome) and inserted_at >= ^attempt.admitted_at and
          inserted_at <= ^attempt.deadline
      )

    query = if sequence, do: Ash.Query.filter(query, sequence == ^sequence), else: query

    query =
      if fence,
        do:
          Ash.Query.filter(
            query,
            generation == ^fence.generation and workflow_id == ^fence.workflow_id
          ),
        else: query

    case query
         |> Ash.Query.sort(inserted_at: :asc, id: :asc)
         |> Ash.Query.limit(1)
         |> Ash.read!(actor: SystemActor.compute()) do
      [] -> nil
      [event] -> %{outcome: event.measurement_outcome, at: event.inserted_at}
    end
  end

  @spec activation_evidence(WorkflowServiceLevelAttempt.t(), RelocationRetry.t()) ::
          evidence() | nil
  defp activation_evidence(attempt, retry) do
    ready =
      terminal(attempt, "ReadinessRequest", retry.start_operation_id, nil, %{
        generation: retry.start_generation,
        workflow_id: retry.relocation_id
      })

    operation =
      case Ledger.read!(Operation, id: retry.start_operation_id) do
        [op]
        when op.kind == :start and op.relocation_id == retry.relocation_id and
               op.generation == retry.start_generation and op.vm_id == retry.vm_id ->
          op

        _ ->
          nil
      end

    if ready && ready.outcome == :failed && operation do
      ready
    else
      with %{outcome: :succeeded} <- ready,
           %Operation{} = op <- operation,
           [physical] <-
             PhysicalOutcome
             |> Ash.Query.filter(
               operation_id == ^op.id and fragment("?->>'state'", observation) == "running"
             )
             |> Ash.Query.sort(sequence: :asc)
             |> Ash.Query.limit(1)
             |> Ash.read!(actor: SystemActor.compute()),
           {:ok, proof} <- OverallsProtocol.Execution.outcome(physical.observation),
           true <-
             proof.id == physical.id and proof.operation_id == op.id and
               proof.vm_id == op.vm_id and proof.placement_id == op.placement_id and
               proof.execution_epoch == op.execution_epoch and proof.generation == op.generation and
               physical.host_id == op.command_snapshot["host_id"],
           true <-
             DateTime.compare(physical.inserted_at, attempt.admitted_at) != :lt and
               DateTime.compare(physical.inserted_at, attempt.deadline) != :gt do
        at =
          if DateTime.compare(physical.inserted_at, ready.at) == :gt,
            do: physical.inserted_at,
            else: ready.at

        %{outcome: :succeeded, at: at}
      else
        _ -> nil
      end
    end
  end

  @spec persist!(WorkflowServiceLevelAttempt.t(), decision()) :: 0 | 1
  defp persist!(attempt, :pending) do
    Ledger.update!(attempt, :check_pending, %{checked_at: Ledger.now()})
    0
  end

  defp persist!(attempt, {:excluded, outcome, at, duration}) do
    Ledger.update!(attempt, :finish, %{
      excluded_outcome: outcome,
      completed_at: at,
      duration_us: duration
    })

    1
  end

  defp persist!(attempt, {:finished, success, at, duration}) do
    finished =
      Ledger.update!(attempt, :finish, %{
        success: success,
        completed_at: at,
        duration_us: duration
      })

    ServiceLevelTotals.add!(finished)
    1
  end
end
