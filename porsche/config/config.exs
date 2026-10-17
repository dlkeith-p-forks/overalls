import Config

config :overalls_diagnostics, events_catalog: Porsche.Events

config :logger,
  handle_otp_reports: true,
  handle_sasl_reports: true,
  translators: [{Porsche.OTPReports, :translate}, {Logger.Translator, :translate}]

# @cc [owner:ghuntley,label:security] porsche-logger-metadata-allowlist
# The Porsche logger MUST use the shared canonical JSON envelope. Session
# credentials, approval links and raw commands MUST NOT be serialized; the
# formatter projects only reviewed Porsche.Events metadata.
config :logger, :default_handler,
  config: [type: :standard_error],
  formatter: {Overalls.Diagnostics.Formatter, catalog: Porsche.Events, service: :porsche}
