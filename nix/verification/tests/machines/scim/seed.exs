# @cc [owner:ghuntley,label:security;verification] scim-machine-fixture-custody
# The bearer token MUST stay in a private VM file and MUST NOT enter output.
# Enabling mirrors the administrator :enable operation's ledger transaction
# (digest-only persistence plus native team retirement); the passkey-elevated
# Control Room path is covered by LiveView tests, not by this fixture.
defmodule ScimMachineFixture do
  alias Marshall.Compute.Ledger

  @spec main() :: :ok
  def main do
    {:ok, _} = Application.ensure_all_started(:marshall)

    [bootstrap] = Ledger.read!(Marshall.Accounts.AdminBootstrap, id: "installation")
    Ledger.update!(bootstrap, :complete, %{})

    owner = Ash.Seed.seed!(Marshall.Accounts.User, %{email: "native-owner@example.test"})

    # The exactly-one-owner constraint is checked at commit, so the native team
    # and its owner membership are inserted together.
    {:ok, _} =
      Marshall.Repo.transaction(fn ->
        team =
          Ash.Seed.seed!(Marshall.Teams.Team, %{
            name: "legacy-native",
            management_mode: :native,
            created_by_id: owner.id
          })

        Ash.Seed.seed!(Marshall.Teams.TeamMember, %{
          team_id: team.id,
          user_id: owner.id,
          recorded_by_id: owner.id,
          role: :owner
        })
      end)

    token = "scim_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    {:ok, _} =
      Ledger.transaction(fn ->
        Ledger.create!(Marshall.Scim.Configuration, :create, %{
          token_digest: Marshall.Scim.Auth.digest(token),
          state: :enabled,
          enabled_at: Ledger.now()
        })

        Marshall.Scim.TeamRetirement.retire_native_teams!()
      end)

    path = "/run/overalls-test/scim-token"
    File.write!(path, token)
    File.chmod!(path, 0o600)
    :ok
  end
end

ScimMachineFixture.main()
