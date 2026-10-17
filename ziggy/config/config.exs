import Config

config :overalls_diagnostics, events_catalog: Ziggy.Events

# @cc [owner:ghuntley,label:security] canonical-structured-log-envelope
# The Ziggy logger MUST use the shared canonical JSON envelope. Provider
# credentials, request/response content and model identifiers MUST NOT be
# serialized; the formatter projects only reviewed Ziggy.Events metadata.
config :logger, :default_handler,
  config: [type: :standard_error],
  formatter: {Overalls.Diagnostics.Formatter, catalog: Ziggy.Events, service: :ziggy}
