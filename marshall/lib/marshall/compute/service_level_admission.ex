defmodule Marshall.Compute.ServiceLevelAdmission do
  @moduledoc "Reliability admissions commit with their operation or canonical SSH receipt."
  use Ash.Resource.Change
  alias Marshall.Compute.{Ledger, Operation, ServiceLevelAttempt}

  # @cc [owner:ghuntley,label:durability;accounting] service-level-admission-transaction
  # Every new executable operation MUST admit one physical measurement inside
  # its enqueue transaction; provision additionally admits creation-to-ready
  # unless the catalog image carries no guest agents, which can never report
  # guest_ready and therefore MUST NOT enter the creation-to-ready denominator.
  # An accepted canonical SSH receipt linked to a measured operation MUST admit
  # one SSH physical measurement in its own transaction, retaining the original
  # physical admission/deadline. Old unmeasured operations remain outside this
  # rollout's denominator. Replay MUST NOT admit again or reset a deadline.
  # Measurements MUST NOT mutate execution, reservations or user receipts.
  @impl true
  def change(changeset, _, _) do
    Ash.Changeset.after_action(changeset, fn _, result ->
      case result do
        %Operation{} = operation ->
          admit!(operation, :lilly_physical)

          if operation.kind == :provision and guest_ready_measurable?(operation),
            do: admit!(operation, :marshall_ready)

        %Marshall.SSH.Request{status: :accepted, operation_id: id} when not is_nil(id) ->
          operation = Ledger.lock!(Operation, id)
          admit!(operation, :porsche_physical)

        %Marshall.SSH.Request{} = request ->
          Marshall.Compute.WorkflowServiceLevels.admit!(request)

        _ ->
          :ok
      end

      {:ok, result}
    end)
  end

  # @cc [owner:ghuntley,label:product;capacity] creation-to-ready-waived-by-capability
  # Only a known image whose agent set lacks the readiness capability waives the
  # creation-to-ready service level; an absent or unknown snapshot image MUST keep
  # the measurement so a misrouted provision is still accounted against it.
  @spec guest_ready_measurable?(Operation.t()) :: boolean()
  defp guest_ready_measurable?(operation) do
    case Marshall.Compute.Images.guest_capabilities(operation.command_snapshot["image_id"]) do
      %{available: true, readiness: readiness} -> readiness
      %{available: false} -> true
    end
  end

  @spec admit!(Operation.t(), :marshall_ready | :lilly_physical | :porsche_physical) :: :ok
  defp admit!(operation, service) do
    Marshall.Compute.ServiceLevelTotals.ensure!(service)
    existing = Ledger.read!(ServiceLevelAttempt, operation_id: operation.id, service: service)

    physical =
      if service == :porsche_physical do
        List.first(
          Ledger.read!(ServiceLevelAttempt, operation_id: operation.id, service: :lilly_physical)
        )
      end

    if existing == [] and (service != :porsche_physical or not is_nil(physical)) do
      now = Ledger.now()
      profile = operation.command_snapshot["profile"]

      seconds =
        case operation.kind do
          kind when kind in [:provision, :start] ->
            if(profile == "inception", do: 3_000, else: 600)

          _ ->
            120
        end

      Ledger.create!(ServiceLevelAttempt, :admit, %{
        operation_id: operation.id,
        service: service,
        admitted_at: if(physical, do: physical.admitted_at, else: now),
        deadline: if(physical, do: physical.deadline, else: DateTime.add(now, seconds, :second))
      })
    end

    :ok
  end
end
