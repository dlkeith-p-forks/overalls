import Config

config :overalls_diagnostics, events_catalog: Galileo.Events

config :logger, :default_handler,
  config: [type: :standard_error],
  formatter: {Overalls.Diagnostics.Formatter, catalog: Galileo.Events, service: :galileo}

if config_env() in [:dev, :test] do
  config :covenant,
    contracts_dir: "contracts",
    test_paths: ["test/contract"],
    sibling_dir: false,
    results_dir: "_build/covenant/results"
end
