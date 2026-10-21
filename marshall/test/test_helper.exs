unless Code.ensure_loaded?(Overalls.HegelFixtures) do
  Code.require_file("../../scripts/test/hegel_fixtures.exs", __DIR__)
end

Code.require_file("../../scripts/test/ssh_key_callback.exs", __DIR__)

# Match Lilly's test helper: local connector fixtures use a private hostd,
# not the deployed service identity inherited from the developer's shell.
# Clear the read-once cache as well as the environment before any fixture runs.
System.delete_env("LILLY_SERVICE_UID")
:persistent_term.erase({Lilly.Host.Privilege, :service_uid})

ExUnit.start(
  exclude: [:distributed, :host, :capacity],
  formatters: [ExUnit.CLIFormatter, Covenant.Formatter]
)

Ecto.Adapters.SQL.Sandbox.mode(Marshall.Repo, :manual)
