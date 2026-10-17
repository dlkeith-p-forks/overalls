import Config

config :overalls_diagnostics, events_catalog: Galileo.Events

config :logger, :default_handler,
  config: [type: :standard_error],
  formatter: {Overalls.Diagnostics.Formatter, catalog: Galileo.Events, service: :galileo}
