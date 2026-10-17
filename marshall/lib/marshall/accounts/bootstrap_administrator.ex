defmodule Marshall.Accounts.BootstrapAdministrator do
  @moduledoc "Serializes successful first registration against the permanent bootstrap latch."
  use Ash.Resource.Change
  alias Marshall.Accounts.{AdminBootstrap, AdminEvent, User}
  alias Marshall.Compute.Ledger
  require Marshall.Events

  # @cc [owner:ghuntley,label:security;concurrency] admin-bootstrap-once
  # Registration MUST hold the singleton lock before inserting/upserting a user.
  # Only a successful registration with an incomplete latch may grant bootstrap
  # authority. Membership, audit and latch MUST commit together; failures roll back.
  # Completed bootstrap MUST never reopen merely because administrators disappear.

  # @cc [owner:ghuntley,label:observability] admin-bootstrap-event-after-commit
  # The bootstrap outcome event MUST be emitted only after the registration
  # transaction commits, and only for a registration that actually elevated the
  # account in that transaction; later sign-ins of existing administrators MUST
  # not emit it.
  @impl true
  def change(changeset, _, _) do
    changeset
    |> Ash.Changeset.before_action(fn changeset ->
      Ledger.lock!(AdminBootstrap, "installation") || raise "missing admin bootstrap migration"
      changeset
    end)
    |> Ash.Changeset.after_action(fn _, user ->
      case Ledger.read!(AdminBootstrap, id: "installation") do
        [%{completed: false} = bootstrap] ->
          Ledger.update!(user, :assign_administrator, %{administrator: true})
          Ledger.update!(bootstrap, :complete, %{})

          Ledger.create!(AdminEvent, :record, %{
            actor_id: user.id,
            target_id: user.id,
            kind: :bootstrap
          })

          {:ok,
           user
           |> Map.put(:administrator, true)
           |> Ash.Resource.put_metadata(:bootstrap_administrator, true)}

        [%{completed: true}] ->
          {:ok, user}
      end
    end)
    |> Ash.Changeset.after_transaction(fn
      _, {:ok, %User{__metadata__: %{bootstrap_administrator: true}} = user} ->
        unless Marshall.Repo.in_transaction?() do
          Marshall.Events.emit("admin.bootstrapped", user_id: user.id)
        end

        {:ok, user}

      _, result ->
        result
    end)
  end
end
