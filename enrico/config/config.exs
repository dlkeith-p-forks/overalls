import Config

config :overalls_diagnostics, events_catalog: Enrico.Events

config :logger, :default_handler,
  config: [type: :standard_error],
  formatter: {Overalls.Diagnostics.Formatter, catalog: Enrico.Events, service: :enrico}
