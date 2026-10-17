import Config

config :overalls_diagnostics, events_catalog: Lilly.Events

config :ash, default_string_length_count: :codepoints

config :lilly, ash_domains: [Lilly.Lifecycle]

config :logger,
  handle_otp_reports: true,
  handle_sasl_reports: true,
  translators: [{Lilly.OTPReports, :translate}, {Logger.Translator, :translate}]

config :logger, :default_handler,
  config: [type: :standard_error],
  formatter: {Overalls.Diagnostics.Formatter, catalog: Lilly.Events, service: :lilly}
