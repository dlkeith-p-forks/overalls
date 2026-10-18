defmodule Marshall.Access.Pins do
  @moduledoc """
  Transactional per-user machine pins (ADR-0193).

  Pinning and unpinning serialize with lifecycle on the VM row lock, so a
  pin and a delete request for the same machine cannot interleave. The
  lifecycle coordinator reads `owner_pinned?/1` under that same lock, and the
  two VM archive sites call `remove_for_vm!/1` in their archive transaction.
  """
  use Ash.Resource.Actions.Implementation
  alias Marshall.Access.{Authorization, Pin}
  alias Marshall.Accounts.User
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Ledger, VirtualMachine}
  require Ash.Query
  require Marshall.Events

  @pin_limit 20

  @type outcome :: {:pinned | :unpinned | :unchanged, Pin.t()}

  @doc "The most machines one user may hold pinned at once."
  @spec limit() :: pos_integer()
  def limit, do: @pin_limit

  @impl true
  def run(input, options, context) do
    vm_id = input.arguments.vm_id

    result =
      Ledger.transaction(
        fn ->
          case options[:operation] do
            :pin -> pin!(vm_id, context.actor)
            :unpin -> unpin!(vm_id, context.actor)
          end
        end,
        context.actor
      )

    case result do
      {:ok, {change, %Pin{} = pin}} ->
        unless Marshall.Repo.in_transaction?(), do: emit_change(change, pin.vm_id)
        {:ok, pin}

      {:error, reason} when is_atom(reason) ->
        unless Marshall.Repo.in_transaction?() do
          Marshall.Events.emit("vm.pin_refused", vm_id: vm_id, reason: reason)
        end

        {:error, Marshall.Compute.Error.exception(reason: reason)}

      other ->
        other
    end
  end

  # Outcome events follow the outer commit; idempotent repeats emit nothing.
  @spec emit_change(:pinned | :unpinned | :unchanged, String.t()) :: :ok
  defp emit_change(:pinned, vm_id), do: Marshall.Events.emit("vm.pinned", vm_id: vm_id)
  defp emit_change(:unpinned, vm_id), do: Marshall.Events.emit("vm.unpinned", vm_id: vm_id)
  defp emit_change(:unchanged, _vm_id), do: :ok

  # @cc [owner:ghuntley,label:security;product] pin-current-read-access
  # Pinning MUST take the VM row lock, recheck current Cedar read access under
  # it and refuse a VM with deleted intent or an archived row (`vm_deleted`).
  # It MUST refuse a 21st pinned machine for one user with `pin_limit`, counted
  # under a per-user advisory lock so concurrent pins cannot exceed the cap.
  # Pinning an already pinned machine MUST return the existing row unchanged.
  # A machine whose observed state is `failed` MUST NOT gain a new pin
  # (`machine_failed`); a pin it already holds stays and MAY be unpinned.
  # Unpinning needs only a live pin row, not current read access, so a user
  # whose access ended can still clear the pin; a never-pinned machine refuses.
  @spec pin!(String.t(), User.t()) :: outcome()
  defp pin!(vm_id, %User{id: user_id} = actor) do
    lock_user!(user_id)
    vm = Authorization.live_vm!(vm_id, actor, "read")

    if vm.owner_id == actor.id and
         (vm.desired_state == :paused or vm.observed_state in [:paused, :stopped]) do
      Marshall.Compute.Wake.request_locked!(vm, :pin, actor)
    end

    case lock_pin(user_id, vm.id) do
      %Pin{state: :pinned} = pin ->
        {:unchanged, pin}

      %Pin{state: :unpinned} = pin ->
        refuse_failed!(vm)
        check_limit!(user_id)
        {:pinned, Ledger.update!(pin, :repin, %{pinned_at: Ledger.now()})}

      nil ->
        refuse_failed!(vm)
        check_limit!(user_id)

        {:pinned,
         Ledger.create!(Pin, :pin, %{user_id: user_id, vm_id: vm.id, pinned_at: Ledger.now()})}
    end
  end

  defp pin!(_vm_id, _actor), do: Ledger.rollback(:forbidden)

  @spec unpin!(String.t(), User.t()) :: outcome()
  defp unpin!(vm_id, %User{id: user_id}) do
    lock_user!(user_id)
    # An archived VM has no live pins left (`remove_for_vm!/1`), so the live read suffices.
    _vm = Ledger.lock!(VirtualMachine, vm_id) || Ledger.rollback(:forbidden)

    case lock_pin(user_id, vm_id) do
      %Pin{state: :unpinned} = pin -> {:unchanged, pin}
      %Pin{state: :pinned} = pin -> {:unpinned, Ledger.update!(pin, :unpin, %{})}
      nil -> Ledger.rollback(:forbidden)
    end
  end

  defp unpin!(_vm_id, _actor), do: Ledger.rollback(:forbidden)

  @spec lock_user!(String.t()) :: :ok
  defp lock_user!(user_id) do
    Ecto.Adapters.SQL.query!(
      Marshall.Repo,
      "SELECT pg_advisory_xact_lock(hashtextextended($1, 0))",
      ["pins:#{user_id}"],
      log: false
    )

    :ok
  end

  @spec lock_pin(String.t(), String.t()) :: Pin.t() | nil
  defp lock_pin(user_id, vm_id) do
    Pin
    |> Ash.Query.filter(user_id == ^user_id and vm_id == ^vm_id)
    |> Ash.Query.lock(:for_update)
    |> Ash.read_one!(actor: SystemActor.compute())
  end

  @spec refuse_failed!(VirtualMachine.t()) :: :ok
  defp refuse_failed!(%VirtualMachine{observed_state: :failed}),
    do: Ledger.rollback(:machine_failed)

  defp refuse_failed!(_vm), do: :ok

  @spec check_limit!(String.t()) :: :ok
  defp check_limit!(user_id) do
    if length(pinned_rows(user_id, @pin_limit)) >= @pin_limit, do: Ledger.rollback(:pin_limit)
    :ok
  end

  @doc "The actor's pinned VM ids, newest pin first, bounded by the pin limit."
  @spec pinned_vm_ids(term()) :: [String.t()]
  def pinned_vm_ids(%User{id: user_id}),
    do: user_id |> pinned_rows(@pin_limit) |> Enum.map(& &1.vm_id)

  def pinned_vm_ids(_actor), do: []

  @doc "Whether the actor currently holds a live pin on the VM."
  @spec pinned?(VirtualMachine.t(), term()) :: boolean()
  def pinned?(%VirtualMachine{id: vm_id}, %User{id: user_id}),
    do: Ledger.read!(Pin, vm_id: vm_id, user_id: user_id, state: :pinned) != []

  def pinned?(_vm, _actor), do: false

  # @cc [owner:ghuntley,label:product;security] pin-owner-delete-guard
  # The deletion guard MUST consult only the VM owner's live `pinned` row, read
  # under the VM lock the lifecycle coordinator already holds. Pins held by
  # other users MUST NOT block deletion; an `unpinned` or archived owner row
  # MUST NOT block deletion.
  @doc "Whether the VM's owner currently holds it pinned. Callers hold the VM lock."
  @spec owner_pinned?(VirtualMachine.t()) :: boolean()
  def owner_pinned?(%VirtualMachine{id: vm_id, owner_id: owner_id}),
    do: Ledger.read!(Pin, vm_id: vm_id, user_id: owner_id, state: :pinned) != []

  # @cc [owner:ghuntley,label:product;recovery] pin-removed-on-archive
  # Archiving a VM MUST archive every live pin on it in the same transaction,
  # whatever its state or holder, so no live pin row outlives its machine.
  # Account deletion MUST archive the departing owner's own pins on each owned
  # VM inside the delete transaction before the owner guard runs; it MUST NOT
  # touch other users' pins on that VM, which the archive removes later.
  @doc "Archive every live pin on a VM. Callers hold the VM lock inside the archive transaction."
  @spec remove_for_vm!(String.t()) :: :ok
  def remove_for_vm!(vm_id) do
    # One live row per user/VM pair, so this is bounded by the VM's readers.
    Pin
    |> Ash.Query.filter(vm_id == ^vm_id)
    |> Ash.read!(actor: SystemActor.compute())
    |> Enum.each(&Ledger.archive!(&1, :remove))
  end

  @doc "Archive one user's live pin on a VM. Account deletion uses this for the owner."
  @spec remove_for_user_vm!(String.t(), String.t()) :: :ok
  def remove_for_user_vm!(user_id, vm_id) do
    Pin
    |> Ash.Query.filter(user_id == ^user_id and vm_id == ^vm_id)
    |> Ash.read!(actor: SystemActor.compute())
    |> Enum.each(&Ledger.archive!(&1, :remove))
  end

  @spec pinned_rows(String.t(), pos_integer()) :: [Pin.t()]
  defp pinned_rows(user_id, limit) do
    Pin
    |> Ash.Query.filter(user_id == ^user_id and state == :pinned)
    |> Ash.Query.sort(pinned_at: :desc, id: :asc)
    |> Ash.Query.limit(limit)
    |> Ash.read!(actor: SystemActor.compute())
  end
end
