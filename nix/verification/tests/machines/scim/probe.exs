# @cc [owner:ghuntley,label:verification] scim-machine-probe-read-only
# Probes MUST only read durable state and MUST print nothing but a pass marker;
# any mismatch halts non-zero so the machine test fails at that subtest.
defmodule ScimMachineProbe do
  import Ecto.Query
  require Ash.Query

  alias Marshall.Authorization.SystemActor

  @spec main(String.t()) :: no_return()
  def main(check) do
    {:ok, _} = Application.ensure_all_started(:marshall)

    if check!(check) do
      IO.puts("scim-probe-ok #{check}")
      System.halt(0)
    else
      IO.puts(:stderr, "scim-probe-failed #{check}")
      System.halt(1)
    end
  end

  @spec check!(String.t()) :: boolean()
  defp check!("native-retiring") do
    [team] = teams(name: "legacy-native")
    team.management_mode == :retiring and jobs("Marshall.Scim.TeamRetirementWorker") > 0
  end

  defp check!("group-synced") do
    [team] = teams(scim_external_id: "ext-engineering")
    owner = Marshall.Teams.ServiceOwner.get!()
    [alice] = users("ext-alice")

    members =
      Marshall.Teams.TeamMember
      |> Ash.Query.filter(team_id == ^team.id)
      |> Ash.read!(actor: SystemActor.compute())

    owners = for %{role: :owner, user_id: id} <- members, do: id

    team.management_mode == :scim_managed and owners == [owner.id] and
      Enum.any?(members, &(&1.user_id == alice.id))
  end

  defp check!("user-retiring") do
    [alice] = users("ext-alice")
    seconds = DateTime.diff(alice.scim_retirement_deadline, DateTime.utc_now())
    alice.active == false and seconds in (7 * 86_400 - 3_600)..(7 * 86_400)
  end

  defp check!(_), do: false

  @spec teams(keyword()) :: [Marshall.Teams.Team.t()]
  defp teams(filter) do
    Marshall.Teams.Team
    |> Ash.Query.filter(^filter)
    |> Ash.read!(actor: SystemActor.compute())
  end

  @spec users(String.t()) :: [Marshall.Accounts.User.t()]
  defp users(external_id) do
    Marshall.Accounts.User
    |> Ash.Query.for_read(:internal_lookup, %{}, actor: SystemActor.compute())
    |> Ash.Query.filter(scim_external_id == ^external_id)
    |> Ash.read!(actor: SystemActor.compute())
  end

  @spec jobs(String.t()) :: non_neg_integer()
  defp jobs(worker) do
    Marshall.Repo.aggregate(from(j in Oban.Job, where: j.worker == ^worker), :count)
  end
end

ScimMachineProbe.main(System.fetch_env!("SCIM_PROBE"))
