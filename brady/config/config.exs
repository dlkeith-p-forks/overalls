import Config

config :overalls_diagnostics, events_catalog: Brady.Events

config :logger, :default_handler,
  config: [type: :standard_error],
  formatter: {Overalls.Diagnostics.Formatter, catalog: Brady.Events, service: :brady}
