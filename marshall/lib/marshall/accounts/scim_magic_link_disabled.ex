defmodule Marshall.Accounts.ScimMagicLinkDisabled do
  @moduledoc "Rejects magic-link authentication while SCIM owns identity lifecycle."
  use Ash.Resource.Validation

  @impl true
  @spec supports(keyword()) :: [module()]
  def supports(_opts), do: [Ash.Changeset, Ash.ActionInput]

  @impl true
  @spec validate(Ash.Changeset.t() | Ash.ActionInput.t(), keyword(), map()) ::
          :ok | {:error, keyword()}
  def validate(_subject, _opts, _context) do
    if Marshall.Scim.enabled?(),
      do: {:error, message: "Magic-link sign-in is disabled while SCIM is enabled."},
      else: :ok
  end
end
