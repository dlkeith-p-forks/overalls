import Config

config :overalls_diagnostics, events_catalog: Ziggy.Events

# @cc [owner:ghuntley,label:security] canonical-structured-log-envelope
# The Ziggy logger MUST use the shared canonical JSON envelope. Provider
# credentials, request/response content and model identifiers MUST NOT be
# serialized; the formatter projects only reviewed Ziggy.Events metadata.
config :logger, :default_handler,
  config: [type: :standard_error],
  formatter: {Overalls.Diagnostics.Formatter, catalog: Ziggy.Events, service: :ziggy}

if config_env() in [:dev, :test] do
  config :covenant,
    contracts_dir: "contracts",
    test_paths: ["test/contract"],
    sibling_dir: false,
    results_dir: "_build/covenant/results"
end
