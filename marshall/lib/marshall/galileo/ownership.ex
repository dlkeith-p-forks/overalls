defmodule Marshall.Galileo.Ownership do
  @moduledoc "Fresh owner liveness for integration admission and configuration views."
  alias Marshall.Accounts.{Security, User}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Galileo.Integration
  alias Marshall.Teams.Team
  require Ash.Query

  # @cc [owner:ghuntley,label:security] galileo-owner-current-liveness
  # An integration owner MUST be a current non-retired user or an existing
  # unarchived team. Retained memberships and attachments MUST NOT establish
  # liveness of an archived team; missing ownership MUST fail closed.
  @spec live?(Integration.t()) :: boolean()
  def live?(%Integration{owner_id: owner_id}) when is_binary(owner_id),
    do: match?(%User{deleted_at: nil, active: true}, Security.current(owner_id))

  def live?(%Integration{team_id: team_id}) when is_binary(team_id) do
    Team
    |> Ash.Query.filter(id == ^team_id)
    |> Ash.exists?(actor: SystemActor.compute())
  end

  def live?(%Integration{}), do: false
end
