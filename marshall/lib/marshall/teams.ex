defmodule Marshall.Teams do
  @moduledoc "Shared machines and resources across accounts with owner/admin/member roles."
  use Ash.Domain, otp_app: :marshall, extensions: [AshPaperTrail.Domain]

  paper_trail do
    include_versions? true
  end

  resources do
    resource Marshall.Teams.Team
    resource Marshall.Teams.TeamMember
    resource Marshall.Teams.Transfer

    resource Marshall.Teams.Team do
      define :list_teams, action: :list_for_user
      define :list_all_teams, action: :list_all_for_user
      define :run_create_team, action: :create_team
      define :run_set_team_member, action: :set_member
      define :list_team_members, action: :list_members
      define :list_team_transfers, action: :list_transfers
    end
  end

  @doc """
  Create a team or reuse the caller's existing active team of the same name.

  Reuse requires the original creator to remain its current owner. The supplied
  idempotency key is not a durable request receipt: SSH request-id replay is
  persisted separately by Marshall.SSH.Request, including its original result.
  """
  @spec create_team(map(), keyword()) :: {:ok, Marshall.Teams.Team.t()} | {:error, term()}
  def create_team(arguments, options \\ []),
    do:
      Marshall.Compute.Ledger.commit_scope(fn ->
        run_create_team(arguments, options)
      end)

  @spec set_team_member(map(), keyword()) :: {:ok, map()} | {:error, term()}
  def set_team_member(arguments, options \\ []),
    do:
      Marshall.Compute.Ledger.commit_scope(fn ->
        run_set_team_member(arguments, options)
      end)

  @doc "Whether native team mutation is admitted for `team` (ADR-0229)."
  defdelegate native_mutable?(team), to: Marshall.Teams.Fence

  @doc "Whether native team creation is admitted (false while SCIM is enabled)."
  defdelegate creation_open?(), to: Marshall.Teams.Fence

  @doc "The hidden SCIM service owner account, or nil when it is missing."
  defdelegate service_owner(), to: Marshall.Teams.ServiceOwner, as: :get

  @doc "Current membership lookup for trusted coordinators."
  defdelegate member?(team_id, user_id), to: Marshall.Teams.Coordinator
end
