defmodule Marshall.Accounts.ProfileLocale do
  @moduledoc "Self-service language preference, scoped to the authenticated account."
  use Ash.Resource.Actions.Implementation
  alias Marshall.Accounts.{Security, User}
  alias Marshall.Compute.Ledger
  alias Marshall.Localization, as: Locale

  # @cc [owner:ghuntley,label:security] locale-self-only
  # The authenticated actor's locked row MUST be the only update target.
  # Nil clears the override; unsupported locales MUST fail without a write.
  @impl true
  @spec run(Ash.ActionInput.t(), keyword(), map()) :: {:ok, map()} | {:error, term()}
  def run(input, _, %{actor: %User{} = actor}) do
    Ledger.transaction(fn ->
      user = Security.lock_user!(actor.id)
      supplied = input.arguments[:locale]
      locale = Locale.normalize(supplied)
      unless is_nil(supplied) or locale, do: Ledger.rollback(:invalid_locale)
      updated = Ledger.update!(user, :store_locale, %{locale: locale})
      %{user_id: updated.id, locale: updated.locale}
    end)
  end

  def run(_, _, _), do: {:error, Ash.Error.Forbidden.exception([])}
end
