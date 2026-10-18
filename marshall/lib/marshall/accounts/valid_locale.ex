defmodule Marshall.Accounts.ValidLocale do
  @moduledoc "Resource-level validation of a persisted language preference."
  use Ash.Resource.Validation

  @impl true
  @spec describe(keyword()) :: keyword()
  def describe(_opts), do: [message: "must be a supported language", vars: []]

  # @cc [owner:ghuntley,label:security] stored-locale-supported
  # Internal updates MUST reject every non-nil unsupported locale.
  @impl true
  @spec validate(Ash.Changeset.t(), keyword(), map()) :: :ok | {:error, keyword()}
  def validate(changeset, _opts, _context) do
    case Ash.Changeset.get_attribute(changeset, :locale) do
      nil ->
        :ok

      locale ->
        if locale == Marshall.Localization.normalize(locale),
          do: :ok,
          else: {:error, field: :locale}
    end
  end
end
