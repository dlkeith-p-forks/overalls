defmodule Marshall.Scim.TeamRetirementWorker do
  @moduledoc "Finalizes SCIM team retirement after the grace period."
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 10,
    unique: [period: 86_400, keys: [:team_id]]

  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.{Ledger, Lifecycle, VirtualMachine}
  alias Marshall.Teams.Team
  require Ash.Query

  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:error, term()}
  def perform(%Oban.Job{args: %{"team_id" => id}}) do
    case Ash.get(Team, id, actor: SystemActor.compute(), not_found_error?: false) do
      {:ok, nil} -> :ok
      {:ok, team} -> finalize(team)
      {:error, reason} -> {:error, reason}
    end
  end

  defp finalize(%{management_mode: mode}) when mode not in [:retiring, :handoff_pending], do: :ok

  defp finalize(team) do
    now = DateTime.utc_now()

    if is_nil(team.scim_retirement_deadline) or
         DateTime.compare(team.scim_retirement_deadline, now) == :gt do
      {:snooze, 300}
    else
      Marshall.Scim.TeamCleanup.revoke!(team)

      VirtualMachine
      |> Ash.Query.filter(team_id == ^team.id and desired_state != :deleted)
      |> Ash.read!(actor: SystemActor.compute())
      |> Enum.each(fn vm ->
        _ =
          Lifecycle.delete_for_team(team.id, vm.id, "scim-team:#{team.id}:#{vm.id}")
      end)

      remaining =
        VirtualMachine
        |> Ash.Query.filter(team_id == ^team.id and is_nil(archived_at))
        |> Ash.read!(actor: SystemActor.compute())

      if remaining == [] do
        Marshall.Scim.TeamCleanup.revoke!(team)
        Ledger.archive!(team, :archive)
        :ok
      else
        {:snooze, 300}
      end
    end
  end
end
