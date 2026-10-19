defmodule Marshall.Scim.TeamCleanup do
  @moduledoc "Revokes durable team-owned authority before a SCIM team is archived."

  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias Marshall.Galileo.Integration
  alias Marshall.Teams.{TeamMember, Transfer}
  alias Marshall.Access.Grant
  alias Marshall.Terminal.Session
  require Ash.Query
  require Marshall.Events
  require Marshall.Events

  @spec revoke!(Marshall.Teams.Team.t()) :: :ok
  def revoke!(team) do
    actor = SystemActor.compute()
    archive_team(Integration, :archive, team.id, actor)
    archive_team(TeamMember, :remove, team.id, actor)
    archive_team(Transfer, :archive, team.id, actor)

    VirtualMachine
    |> Ash.Query.filter(team_id == ^team.id)
    |> Ash.read!(actor: actor)
    |> Enum.each(&revoke_machine_authority!(&1, team.id, actor))

    Marshall.Events.emit("scim.team_authority_revoked", team_id: team.id)

    :ok
  end

  defp revoke_machine_authority!(vm, team_id, actor) do
    archive_vm(Grant, :revoke, vm.id, actor)
    archive_vm(Session, :close, vm.id, actor)
    Marshall.Events.emit("scim.team_authority_revoked", team_id: team_id)
  end

  defp archive_team(resource, action, team_id, actor) do
    resource
    |> Ash.Query.filter(team_id == ^team_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(&archive_one(&1, action))
  end

  defp archive_vm(resource, action, vm_id, actor) do
    resource
    |> Ash.Query.filter(vm_id == ^vm_id)
    |> Ash.read!(actor: actor)
    |> Enum.each(&archive_one(&1, action))
  end

  defp archive_one(record, action) do
    try do
      Ledger.archive!(record, action)
    rescue
      _ -> :ok
    end
  end
end
