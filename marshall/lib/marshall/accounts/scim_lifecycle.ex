defmodule Marshall.Accounts.ScimLifecycle do
  @moduledoc """
  SCIM user writes: `active=false` and SCIM `DELETE` enter the retirement grace
  period, `active=true` inside it reactivates, and retired identities are
  immutable. See `Marshall.Accounts.ScimRetirement`.
  """
  use Ash.Resource.Change
  use Gettext, backend: MarshallWeb.Gettext
  alias Marshall.Accounts.{ScimRetirement, User}
  alias Marshall.Compute.Ledger

  @type mode :: :create | :update | :delete
  @typep effect :: :deactivated | :reactivated | :none

  @impl true
  @spec init(keyword()) :: {:ok, keyword()} | {:error, String.t()}
  def init(opts) do
    if Keyword.get(opts, :mode, :update) in [:create, :update, :delete],
      do: {:ok, opts},
      else: {:error, "mode must be :create, :update or :delete"}
  end

  # @cc [owner:ghuntley,label:security;recovery] scim-write-locked-lifecycle
  # Every SCIM user write MUST decide under the user row lock and database
  # clock. Retired identities and the service owner MUST refuse every write.
  # After the deadline, reactivation and identity changes MUST be refused while
  # a SCIM DELETE is still recorded. Repeated deactivation MUST NOT extend the
  # original deadline.
  @impl true
  @spec change(Ash.Changeset.t(), keyword(), Ash.Resource.Change.context()) ::
          Ash.Changeset.t()
  def change(changeset, opts, _context) do
    mode = Keyword.get(opts, :mode, :update)

    changeset
    |> Ash.Changeset.before_action(&decide(&1, mode))
    |> Ash.Changeset.after_action(&commit_effects/2)
  end

  @spec decide(Ash.Changeset.t(), mode()) :: Ash.Changeset.t()
  defp decide(changeset, :create) do
    if Ash.Changeset.get_attribute(changeset, :active) == false do
      changeset
      |> Ash.Changeset.force_change_attribute(
        :scim_retirement_deadline,
        ScimRetirement.deadline_from(Ledger.now())
      )
      |> effect(:deactivated)
    else
      effect(changeset, :none)
    end
  end

  defp decide(changeset, mode) do
    locked = ScimRetirement.lock_user!(changeset.data.id)
    now = Ledger.now()

    cond do
      is_nil(locked) or not is_nil(locked.deleted_at) ->
        refuse(changeset, dgettext("auth", "This identity is permanently retired"))

      ScimRetirement.service_owner?(locked) ->
        refuse(changeset, dgettext("auth", "The SCIM service account cannot be changed"))

      true ->
        decide_live(changeset, locked, now, mode)
    end
  end

  @spec decide_live(Ash.Changeset.t(), User.t(), DateTime.t(), :update | :delete) ::
          Ash.Changeset.t()
  defp decide_live(changeset, locked, now, mode) do
    target_active =
      cond do
        mode == :delete ->
          false

        Ash.Changeset.changing_attribute?(changeset, :active) ->
          Ash.Changeset.get_attribute(changeset, :active)

        true ->
          locked.active
      end

    cond do
      ScimRetirement.due?(locked, now) and (target_active or identity_changed?(changeset, locked)) ->
        refuse(
          changeset,
          dgettext(
            "auth",
            "The retirement grace period has ended; this identity cannot be changed"
          )
        )

      target_active == false ->
        changeset
        |> Ash.Changeset.force_change_attribute(:active, false)
        |> Ash.Changeset.force_change_attribute(
          :scim_retirement_deadline,
          locked.scim_retirement_deadline || ScimRetirement.deadline_from(now)
        )
        |> Ash.Changeset.force_change_attribute(
          :scim_deleted_at,
          if(mode == :delete, do: locked.scim_deleted_at || now, else: locked.scim_deleted_at)
        )
        |> effect(:deactivated)

      locked.active == false ->
        changeset
        |> Ash.Changeset.force_change_attribute(:active, true)
        |> Ash.Changeset.force_change_attribute(:scim_retirement_deadline, nil)
        |> Ash.Changeset.force_change_attribute(:scim_deleted_at, nil)
        |> effect(:reactivated)

      true ->
        effect(changeset, :none)
    end
  end

  @spec identity_changed?(Ash.Changeset.t(), User.t()) :: boolean()
  defp identity_changed?(changeset, locked) do
    Enum.any?([:email, :scim_external_id], fn field ->
      Ash.Changeset.changing_attribute?(changeset, field) and
        to_string(Ash.Changeset.get_attribute(changeset, field)) !=
          to_string(Map.fetch!(locked, field))
    end)
  end

  @spec refuse(Ash.Changeset.t(), String.t()) :: Ash.Changeset.t()
  defp refuse(changeset, message),
    do:
      Ash.Changeset.add_error(
        changeset,
        Ash.Error.Changes.InvalidChanges.exception(fields: [:active], message: message)
      )

  @spec effect(Ash.Changeset.t(), effect()) :: Ash.Changeset.t()
  defp effect(changeset, effect),
    do: Ash.Changeset.put_context(changeset, :scim_lifecycle_effect, effect)

  @spec commit_effects(Ash.Changeset.t(), User.t()) :: {:ok, User.t()}
  defp commit_effects(changeset, record) do
    case changeset.context[:scim_lifecycle_effect] do
      :deactivated -> ScimRetirement.deactivated!(record)
      :reactivated -> ScimRetirement.reactivated!(record)
      _ -> :ok
    end

    {:ok, record}
  end
end
