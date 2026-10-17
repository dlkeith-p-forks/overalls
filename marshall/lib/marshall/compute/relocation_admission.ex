defmodule Marshall.Compute.RelocationAdmission do
  @moduledoc "Authorized automatic relocation admission with durable request identity."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Accounts.AdminEvent
  alias Marshall.Compute.{Host, Ledger, Relocation, RelocationCapacity, VirtualMachine}
  require Marshall.Events

  # @cc [owner:ghuntley,label:security;capacity;concurrency] relocation-user-admission-atomic
  # Admission MUST recheck current manage permission after sorted host locks and
  # the VM lock. New requests MUST reject a changed placement/epoch since lookup.
  # Actor/VM/key retries MUST return the original relocation without reserving
  # again, including retained history, but MUST NOT bypass current authorization.
  # Destination selection, both holds/slots, placement and durable coordination
  # MUST commit atomically. User input MUST NOT choose a destination or mode.
  @impl true
  def run(input, _, context) do
    request = input.arguments

    result =
      Ledger.transaction(
        fn ->
          Ecto.Adapters.SQL.query!(
            Marshall.Repo,
            "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
            ["relocation:#{context.actor.id}:#{request.vm_id}:#{request.idempotency_key}"],
            log: false
          )

          vm =
            case Ledger.history!(VirtualMachine, id: request.vm_id) do
              [vm] -> vm
              [] -> Ledger.rollback(:forbidden)
            end

          Marshall.Access.Authorization.require!(vm, context.actor, "manage")
          authority = {vm.current_placement_id, vm.execution_epoch}

          hosts =
            Host
            |> Ledger.read!()
            |> Enum.sort_by(& &1.id)
            |> Enum.map(&Ledger.lock!(Host, &1.id))

          vm = Ledger.lock_history!(VirtualMachine, vm.id)
          unless vm, do: Ledger.rollback(:forbidden)
          Marshall.Access.Authorization.require!(vm, context.actor, "manage")

          case Ledger.read!(Relocation,
                 vm_id: vm.id,
                 requested_by_id: context.actor.id,
                 request_key: request.idempotency_key
               ) do
            [existing] ->
              existing

            [] ->
              unless {vm.current_placement_id, vm.execution_epoch} == authority and
                       Enum.any?(hosts, &(&1.id == vm.host_id)),
                     do: Ledger.rollback(:placement_changed)

              relocation =
                RelocationCapacity.reserve_locked!(
                  vm,
                  hosts,
                  context.actor,
                  request.idempotency_key
                )

              audit_admin!(context.actor, vm.id)
              relocation
          end
        end,
        context.actor
      )

    case result do
      {:ok, relocation} ->
        unless Marshall.Repo.in_transaction?() do
          Marshall.Events.emit("relocation.admitted",
            vm_id: relocation.vm_id,
            relocation_id: relocation.id,
            host_id: relocation.destination_host_id
          )
        end

        {:ok, relocation}

      {:error, reason} when is_atom(reason) ->
        unless Marshall.Repo.in_transaction?() do
          Marshall.Events.emit("relocation.admission_refused",
            vm_id: vm_id(request),
            reason: reason
          )
        end

        {:error, Marshall.Compute.Error.exception(reason: reason)}

      other ->
        other
    end
  end

  defp vm_id(%{vm_id: id}), do: if(OverallsProtocol.uuid?(id), do: id, else: nil)

  defp audit_admin!(%{administrator: true} = actor, target_id) do
    Ledger.create!(AdminEvent, :record, %{
      actor_id: actor.id,
      target_id: target_id,
      kind: :vm_relocate
    })

    :ok
  end

  defp audit_admin!(_, _), do: :ok
end
