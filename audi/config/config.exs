import Config

config :overalls_diagnostics, events_catalog: Audi.Events

config :logger,
  handle_otp_reports: true,
  handle_sasl_reports: true,
  translators: [{Audi.OTPReports, :translate}, {Logger.Translator, :translate}]

# @cc [owner:ghuntley,label:security] canonical-structured-log-envelope
# The Audi default logger MUST use the shared canonical formatter. Credentials,
# configuration structs and terminal bytes are filtered before serialization.
config :logger, :default_handler,
  config: [type: :standard_error],
  formatter: {Overalls.Diagnostics.Formatter, catalog: Audi.Events, service: :audi}
