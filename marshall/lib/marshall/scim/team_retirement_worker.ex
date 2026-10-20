defmodule Marshall.Scim.TeamRetirementWorker do
  @moduledoc """
  Finalizes SCIM team retirement after the grace period (ADR-0229).

  The job is idempotent: an archived or unknown team, or a team no longer in
  `:retiring` mode, completes without writes. Retirement of a team already
  marked `:retiring` continues even if SCIM is disabled afterwards, because the
  team's native authority was revoked when SCIM became authoritative and
  disabling SCIM does not restore native teams.
  """
  use Oban.Worker,
    queue: :maintenance,
    max_attempts: 20,
    unique: [period: 86_400, keys: [:team_id]]

  alias Marshall.Compute.{Ledger, Lifecycle, VirtualMachine}
  alias Marshall.Teams.Team

  @poll_seconds 60

  # @cc [owner:ghuntley,label:recovery;concurrency] scim-team-retirement-worker
  # Finalization MUST wait for the deadline, request deletion of every live team
  # machine, wait until none remains, then revoke authority and archive the team
  # in one locked transaction that rechecks :retiring. Deletion and archive
  # failures MUST return errors so Oban retries; repeated runs are no-ops.
  @impl Oban.Worker
  @spec perform(Oban.Job.t()) :: :ok | {:snooze, pos_integer()} | {:error, term()}
  def perform(%Oban.Job{args: %{"team_id" => id}}) when is_binary(id) do
    if OverallsProtocol.uuid?(id) do
      case Ledger.read!(Team, id: id) do
        [%Team{management_mode: :retiring} = team] -> finalize(team)
        _ -> :ok
      end
    else
      {:cancel, :invalid_team_id}
    end
  end

  def perform(%Oban.Job{}), do: {:cancel, :invalid_arguments}

  @spec finalize(Team.t()) :: :ok | {:snooze, pos_integer()} | {:error, term()}
  defp finalize(team) do
    now = Ledger.now()

    case team.scim_retirement_deadline do
      %DateTime{} = deadline ->
        if DateTime.compare(deadline, now) == :gt do
          {:snooze, max(DateTime.diff(deadline, now, :second), 1)}
        else
          retire_machines(team)
        end

      nil ->
        retire_machines(team)
    end
  end

  defp retire_machines(team) do
    failures =
      VirtualMachine
      |> Ledger.read!(team_id: team.id)
      |> Enum.reject(&(&1.desired_state == :deleted))
      |> Enum.flat_map(fn vm ->
        case Lifecycle.delete_for_team(team.id, vm.id, "scim-team:#{team.id}:#{vm.id}") do
          {:ok, _} -> []
          {:error, reason} -> [reason]
        end
      end)

    cond do
      failures != [] -> {:error, {:machine_deletion_failed, length(failures)}}
      Ledger.read!(VirtualMachine, team_id: team.id) != [] -> {:snooze, @poll_seconds}
      true -> archive(team.id)
    end
  end

  defp archive(team_id) do
    Ledger.transaction(
      fn ->
        case Ledger.lock!(Team, team_id) do
          %Team{management_mode: :retiring} = team ->
            if Ledger.read!(VirtualMachine, team_id: team.id) != [],
              do: Ledger.rollback(:team_machines_remaining)

            Marshall.Scim.TeamCleanup.archive!(team)

          _ ->
            :ok
        end
      end,
      :system
    )
    |> case do
      {:ok, :ok} -> :ok
      {:error, reason} -> {:error, reason}
    end
  end
end
