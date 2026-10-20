defmodule Marshall.Accounts.DeleteUserMachines do
  @moduledoc "Bounded restart-safe cleanup through existing physical VM lifecycle coordinators."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Accounts.{UserDeletion, Passkey}
  alias Marshall.Compute.{Ledger, VirtualMachine, Lifecycle}
  alias Marshall.Authorization.SystemActor
  require Ash.Query
  require Marshall.Events

  # @cc [owner:ghuntley,label:recovery;capacity] account-deletion-physical-completion
  # Retired identity remains fenced throughout retries. Deletion MUST use the
  # lifecycle coordinator and MUST NOT release capacity or claim completion until
  # every owned VM is archived after physical reclamation. Busy work is retried.
  # Completion MUST pass begin_finalization then complete; a SCIM retirement
  # MUST NOT touch machines or access before its deadline (user-deletion-machine-authority).
  @impl true
  def run(input, _, %{actor: %SystemActor{purpose: :compute}}) do
    deletion = List.first(Ledger.read!(UserDeletion, id: input.arguments.primary_key["id"]))

    cond do
      is_nil(deletion) or deletion.state in [:completed, :cancelled] ->
        {:ok, %{complete: deletion != nil and deletion.state == :completed}}

      not eligible?(deletion) ->
        {:ok, %{complete: false, remaining: deletion.remaining, waiting: true}}

      true ->
        advance(deletion)
    end
  end

  @spec eligible?(UserDeletion.t()) :: boolean()
  defp eligible?(deletion) do
    UserDeletion.machine_deletion_authorized?(
      deletion,
      Marshall.Accounts.Security.current(deletion.user_id),
      Ledger.now()
    )
  end

  @spec advance(UserDeletion.t()) :: {:ok, map()} | {:error, term()}
  defp advance(deletion) do
    vms =
      VirtualMachine
      |> Ash.Query.filter(owner_id == ^deletion.user_id and desired_state != :deleted)
      |> Ash.Query.sort(:id)
      |> Ash.Query.limit(50)
      |> Ash.read!(actor: SystemActor.compute())

    {blocked, deleted} =
      Enum.reduce(vms, {false, 0}, fn vm, {blocked, deleted} ->
        case Lifecycle.delete_for_account(deletion, vm.id) do
          {:ok, _} -> {blocked, deleted + 1}
          {:error, _} -> {true, deleted}
        end
      end)

    result =
      Ledger.transaction(fn ->
        # Serialize with owned-work admission so nothing new appears between
        # the final count and completion (account-admission-fence).
        Marshall.Accounts.AccountLifecycle.retirement_fence!(deletion.user_id)
        deletion = Ledger.lock!(UserDeletion, deletion.id)

        unless deletion.state in [:scheduled, :finalizing] and eligible?(deletion),
          do: Ledger.rollback(:forbidden)

        remaining = Marshall.Accounts.AccountLifecycle.owned_count(deletion.user_id)
        access_pending = cleanup_access!(deletion.user_id)

        deletion =
          Ledger.update!(deletion, :progress, %{remaining: remaining, blocked: blocked})

        deletion =
          if remaining == 0 and not access_pending do
            deletion =
              if deletion.state == :scheduled,
                do: Ledger.update!(deletion, :begin_finalization, %{}),
                else: deletion

            Marshall.Accounts.ScimFinalize.finalize!(deletion)
            Marshall.Accounts.ScimRetirement.release_open!(deletion.user_id)
            Ledger.update!(deletion, :complete, %{completed_at: Ledger.now()})
          else
            deletion
          end

        %{remaining: remaining, complete: deletion.state == :completed, kind: deletion.kind}
      end)

    with {:ok, outcome} <- result do
      unless Marshall.Repo.in_transaction?() do
        emit_progress(deletion.user_id, deleted)

        if blocked,
          do:
            Marshall.Events.emit("account.deletion_blocked",
              user_id: deletion.user_id,
              reason: :machine_cleanup_failed
            )

        if outcome.complete and outcome.kind == :scim_retirement,
          do: Marshall.Events.emit("scim.user_finalized", user_id: deletion.user_id)
      end

      {:ok, Map.delete(outcome, :kind)}
    end
  end

  defp emit_progress(_user_id, 0), do: :ok

  defp emit_progress(user_id, deleted),
    do:
      Marshall.Events.emit("account.deletion_progress", user_id: user_id, deleted_count: deleted)

  # @cc [owner:ghuntley,label:security;recovery] account-deletion-thread-access-cleanup
  # Deleted-user cleanup MUST revoke canonical thread grants as well as machine
  # grants, machine pins and SSH keys through their resource actions, preserving
  # access hints and history. It MUST remain incomplete while any bounded
  # cleanup work remains.
  @spec cleanup_access!(Ash.UUID.t()) :: boolean()
  defp cleanup_access!(id) do
    _ = Marshall.Notifications.revoke_for_user!(id, :account_retired)

    resources = [
      {Marshall.SSH.Key, :revoke},
      {Marshall.Access.Grant, :revoke},
      {Marshall.Threads.Grant, :revoke},
      {Marshall.Access.Pin, :remove}
    ]

    for {resource, action} <- resources do
      resource
      |> Ash.Query.filter(user_id == ^id)
      |> Ash.Query.limit(100)
      |> Ash.read!(actor: SystemActor.compute())
      |> Enum.each(&Ledger.archive!(&1, action))
    end

    Enum.each(Ledger.read!(Passkey, user_id: id), &Ledger.archive!(&1, :destroy))

    Enum.any?(resources, fn {resource, _action} ->
      resource
      |> Ash.Query.filter(user_id == ^id)
      |> Ash.Query.limit(1)
      |> Ash.read!(actor: SystemActor.compute()) != []
    end)
  end
end
