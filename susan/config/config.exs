import Config

config :overalls_diagnostics, events_catalog: Susan.Events

config :ash,
  default_string_length_count: :codepoints,
  default_actions_require_atomic?: true,
  transaction_rollback_on_error?: true,
  redact_sensitive_values_in_errors?: true,
  bulk_actions_default_to_errors?: true,
  known_types: [AshPostgres.Timestamptz, AshPostgres.TimestamptzUsec]

config :susan,
  ecto_repos: [Susan.Repo],
  ash_domains: [Susan.Relay, Susan.Audit]

config :susan, Susan.Repo, migration_lock: :pg_advisory_lock, log: false

# @cc [owner:ghuntley,label:privacy] susan-oban-no-payload
# Oban jobs carry no request data: only maintenance workers with empty args.
config :susan, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  repo: Susan.Repo,
  queues: [maintenance: 1],
  plugins: [
    {Oban.Plugins.Pruner, max_age: 86_400},
    {Oban.Plugins.Cron, crontab: [{"17 3 * * *", Susan.Maintenance.Prune}]}
  ]

config :logger, :default_handler,
  config: [type: :standard_error],
  formatter: {Overalls.Diagnostics.Formatter, catalog: Susan.Events, service: :susan}

if config_env() in [:dev, :test] do
  config :covenant,
    contracts_dir: "contracts",
    test_paths: ["test/contract"],
    sibling_dir: false,
    results_dir: "_build/covenant/results"
end

import_config "#{config_env()}.exs"
