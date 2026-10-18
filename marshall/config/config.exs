# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :overalls_diagnostics, events_catalog: Marshall.Events

# @cc [owner:ghuntley,label:build] offline-time-zone-database
# DateTime zone conversion MUST use the Tz database compiled from the pinned
# hex package; the release MUST NOT fetch IANA data at runtime (ADR-0195).
config :elixir, :time_zone_database, Tz.TimeZoneDatabase

config :marshall, agent_model: "gpt-6-sol"

config :marshall, :thread_modes, %{
  low: %{model: "gpt-6-sol", reasoning_effort: :low},
  medium: %{model: "gpt-6-sol", reasoning_effort: :medium},
  high: %{model: "gpt-6-sol", reasoning_effort: :high},
  ultra: %{model: "gpt-6-sol", reasoning_effort: :ultra}
}

# @cc [owner:ghuntley,label:security] sensitive-phoenix-parameters
# Phoenix parameter filtering MUST include login credentials and terminal byte
# fields and captured launch URLs so request/event diagnostics cannot print
# those payloads, including malformed URLs that might contain credentials.
config :phoenix, :filter_parameters, [
  "password",
  "token",
  "bytes",
  "input",
  "payload",
  "client_data_json",
  "attestation_object",
  "authenticator_data",
  "signature",
  "raw_id",
  "source",
  "visit",
  "receipt"
]

config :marshall, Marshall.Vault, allow_development_key: config_env() in [:dev, :test]
config :marshall, provisioner_allow_insecure_loopback: config_env() in [:dev, :test]
config :marshall, ssh_allow_insecure_loopback: config_env() in [:dev, :test]

# @cc [owner:ghuntley,label:recovery;coordination] migration-lock-survives-long-workers
# Migrators MUST share Ecto's PostgreSQL advisory lock. The lock-holding session
# MUST NOT sit in an idle transaction while another connection runs a migration,
# because the serving idle-transaction deadline would release serialization.
config :marshall, Marshall.Repo, migration_lock: :pg_advisory_lock

config :ash_oban, pro?: false

# @cc [owner:ghuntley,label:coordination] shared-oban-notifier
# Oban MUST use Marshall.Repo with PostgreSQL notifications; node-local
# notifications MUST NOT become the work authority across control-plane replicas.
config :marshall, Oban,
  engine: Oban.Engines.Basic,
  notifier: Oban.Notifiers.Postgres,
  queues: [
    default: 10,
    provisioning: 10,
    mail: 2,
    maintenance: 2,
    certificates: [limit: 1, paused: true]
  ],
  lifeline: [rescue_after: {2, :hours}],
  pruner: [max_age: {1, :day}],
  repo: Marshall.Repo,
  plugins: [{Oban.Plugins.Cron, crontab: [{"* * * * *", Marshall.Enrico.Worker}]}]

# These enable behaviors that will become the default in the next major
# version of Ash. Setting them now opts your application into the new
# behavior and ensures a seamless upgrade. See the backwards compatibility
# guide for an explanation of each setting:
# https://hexdocs.pm/ash/backwards-compatibility-config.html
config :ash,
  allow_forbidden_field_for_relationships_by_default: true,
  include_embedded_source_by_default?: false,
  show_keysets_for_all_actions?: false,
  default_page_type: :keyset,
  policies: [no_filter_static_forbidden_reads?: false],
  keep_read_action_loads_when_loading?: false,
  default_actions_require_atomic?: true,
  read_action_after_action_hooks_in_order?: true,
  bulk_actions_default_to_errors?: true,
  transaction_rollback_on_error?: true,
  redact_sensitive_values_in_errors?: true,
  default_string_length_count: :codepoints,
  many_to_many_destroy_destination_on_match?: true,
  known_types: [AshPostgres.Timestamptz, AshPostgres.TimestamptzUsec]

config :spark,
  formatter: [
    remove_parens?: true,
    "Ash.Resource": [
      section_order: [
        :admin,
        :authentication,
        :token,
        :user_identity,
        :postgres,
        :resource,
        :code_interface,
        :actions,
        :policies,
        :pub_sub,
        :preparations,
        :changes,
        :validations,
        :multitenancy,
        :attributes,
        :relationships,
        :calculations,
        :aggregates,
        :identities
      ]
    ],
    "Ash.Domain": [
      section_order: [:admin, :resources, :policies, :authorization, :domain, :execution]
    ]
  ]

config :marshall,
  ecto_repos: [Marshall.Repo],
  generators: [timestamp_type: :utc_datetime],
  ash_domains: [
    Marshall.Accounts,
    Marshall.Compute,
    Marshall.Access,
    Marshall.SSH,
    Marshall.Ingress,
    Marshall.Editor,
    Marshall.Inference,
    Marshall.Galileo,
    Marshall.Enrico,
    Marshall.Teams,
    Marshall.Terminal,
    Marshall.Agents,
    Marshall.Threads,
    Marshall.Administration
  ],
  capacity_freshness_ms: 5_000,
  pool_busy_grace_ms: 15_000,
  host_authority_ms: 60_000,
  ash_authentication: [return_error_on_invalid_magic_link_token?: true]

# Configure the endpoint
config :marshall, MarshallWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: MarshallWeb.ErrorHTML, json: MarshallWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: Marshall.PubSub,
  live_view: [signing_salt: "im+VBp6F"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :marshall, Marshall.Mailer, adapter: Swoosh.Adapters.Local
config :marshall, mail_from: {"Overalls", "noreply@example.test"}

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  marshall: [
    args:
      ~w(js/app.js css/app.css --bundle --target=es2022 --outdir=../priv/static/assets --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# @cc [owner:ghuntley,label:security] canonical-structured-log-envelope
# The Marshall logger MUST use the shared canonical JSON envelope. Credentials,
# account tokens, guest bytes and encrypted payload plaintext MUST NOT be emitted;
# the formatter projects only reviewed Marshall.Events metadata.
config :logger,
  handle_otp_reports: true,
  handle_sasl_reports: true,
  translators: [{Marshall.OTPReports, :translate}, {Logger.Translator, :translate}]

config :logger, :default_handler,
  config: [type: :standard_error],
  formatter: {Overalls.Diagnostics.Formatter, catalog: Marshall.Events, service: :marshall}

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"

if config_env() in [:dev, :test] do
  config :covenant,
    contracts_dir: "contracts",
    test_paths: ["test/contract"],
    sibling_dir: false,
    results_dir: "_build/covenant/results"
end
