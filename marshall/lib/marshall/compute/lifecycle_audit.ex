defmodule Marshall.Compute.LifecycleAudit do
  @moduledoc "Transactional lifecycle evidence, projected without payloads or secrets."
  use Ash.Resource.Change
  alias Marshall.Compute.{Ledger, LifecycleEvent}

  # @cc [owner:ghuntley,label:security;durability] lifecycle-audit-transaction
  # Resource mutations MUST insert their redacted event inside the same transaction.
  # Audit failure MUST fail the mutation. Payloads, request keys, credentials and
  # arbitrary exception strings MUST NOT enter events. Equal replays create no event.
  @impl true
  def change(changeset, _, _) do
    Ash.Changeset.after_action(changeset, fn changeset, result ->
      record!(changeset, result)
      {:ok, result}
    end)
  end

  @impl true
  def atomic(changeset, _, _), do: {:ok, changeset}

  @impl true
  def batch_change(changesets, _, _), do: changesets

  @impl true
  def after_batch(pairs, _, _) do
    Enum.map(pairs, fn {changeset, result} ->
      record!(changeset, result)
      {:ok, result}
    end)
  end

  defp record!(changeset, result) do
    if changed?(changeset, result) do
      now = Ledger.now()
      resource = changeset.resource
      actor = get_in(changeset.context, [:private, :actor])
      requester = changeset.context[:lifecycle_requester_id]
      human = requester != nil or match?(%Marshall.Accounts.User{}, actor)

      attrs = %{
        actor_kind: if(human, do: :user, else: :system),
        actor_id: requester || if(human, do: actor.id),
        resource_type: resource |> Module.split() |> List.last(),
        resource_id: result.id,
        action: Atom.to_string(changeset.action.name),
        previous_state:
          if(changeset.action_type == :create,
            do: nil,
            else: state(changeset.data, changeset.action.name)
          ),
        next_state: state(result, changeset.action.name),
        vm_id:
          if(resource == Marshall.Compute.VirtualMachine,
            do: result.id,
            else: field(result, :vm_id) || field(result, :source_vm_id)
          ),
        placement_id: field(result, :placement_id) || field(result, :current_placement_id),
        host_id: field(result, :host_id),
        workflow_id: workflow(resource, result),
        operation_id:
          if(resource == Marshall.Compute.Operation,
            do: result.id,
            else: field(result, :operation_id)
          ),
        execution_epoch: field(result, :execution_epoch),
        generation: field(result, :generation),
        sequence: field(result, :sequence),
        measurement_outcome: measurement_outcome(result),
        occurred_at: now,
        expires_at: DateTime.add(now, 90, :day)
      }

      Ledger.create!(LifecycleEvent, :record, attrs)
    end
  end

  # @cc [owner:ghuntley,label:accounting;security] workflow-terminal-evidence
  # Clone source-restoration failure MUST remain append-only failed evidence
  # even when its phase does not change. Only closed terminal categories may
  # enter measurement evidence; phases and arbitrary failure text stay separate.
  @spec measurement_outcome(Ash.Resource.Record.t()) ::
          :succeeded | :failed | :cancelled | :superseded | nil
  def measurement_outcome(%{__struct__: Marshall.Compute.CloneRequest} = row) do
    cond do
      row.failure == "source_restart_failed" -> :failed
      row.phase == :complete -> :succeeded
      row.phase == :cancelled -> :cancelled
      row.phase == :failed -> :failed
      true -> nil
    end
  end

  def measurement_outcome(%{__struct__: Marshall.Compute.Relocation, phase: phase}) do
    case phase do
      :complete -> :succeeded
      :cancelled -> :cancelled
      :deleted -> :superseded
      failed when failed in [:readiness_failed, :activation_failed] -> :failed
      _ -> nil
    end
  end

  def measurement_outcome(%{__struct__: Marshall.Compute.RelocationRetry, status: :superseded}),
    do: :superseded

  def measurement_outcome(%{__struct__: Marshall.Compute.ReadinessRequest, status: :ready}),
    do: :succeeded

  def measurement_outcome(%{__struct__: Marshall.Compute.ReadinessRequest, status: :failed}),
    do: :failed

  def measurement_outcome(_), do: nil

  defp changed?(%{action_type: type}, _) when type in [:create, :destroy], do: true

  defp changed?(changeset, result) do
    changeset.resource
    |> Ash.Resource.Info.attributes()
    |> Enum.reject(&(&1.name in [:updated_at, :inserted_at]))
    |> Enum.any?(fn attr -> Map.get(changeset.data, attr.name) != Map.get(result, attr.name) end)
  end

  defp workflow(resource, result) do
    if resource in [
         Marshall.Compute.CloneRequest,
         Marshall.Compute.ResizeRequest,
         Marshall.Compute.Relocation
       ],
       do: result.id,
       else:
         field(result, :clone_request_id) || field(result, :resize_request_id) ||
           field(result, :relocation_id)
  end

  defp state(record, :observe), do: stringify(field(record, :observed_state))

  defp state(record, _) do
    resource = record.__struct__

    value =
      if AshStateMachine in Spark.extensions(resource),
        do: field(record, AshStateMachine.Info.state_machine_state_attribute!(resource)),
        else: field(record, :phase) || field(record, :status) || field(record, :desired_state)

    stringify(value)
  end

  defp stringify(value) when is_atom(value) and not is_nil(value), do: Atom.to_string(value)
  defp stringify(value), do: value

  defp field(record, key) do
    case Map.get(record, key) do
      %Ash.NotLoaded{} -> nil
      value -> value
    end
  end
end
