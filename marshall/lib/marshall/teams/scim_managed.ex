defmodule Marshall.Teams.ScimManaged do
  @moduledoc "Refuses SCIM writes to teams that SCIM does not manage."
  use Ash.Resource.Validation

  @impl true
  @spec supports(keyword()) :: [module()]
  def supports(_opts), do: [Ash.Changeset]

  @impl true
  @spec validate(Ash.Changeset.t(), keyword(), map()) :: :ok | {:error, Exception.t()}
  def validate(%Ash.Changeset{data: %{management_mode: :scim_managed}}, _opts, _context), do: :ok

  def validate(_changeset, _opts, _context), do: {:error, refusal()}

  @doc "The fixed refusal for a SCIM write to a team SCIM does not manage."
  @spec refusal() :: Exception.t()
  def refusal,
    do:
      Ash.Error.Changes.InvalidChanges.exception(
        fields: [:management_mode],
        message: "team is not managed by SCIM"
      )
end
