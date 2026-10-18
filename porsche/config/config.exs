import Config

config :localize,
  otp_app: :porsche,
  default_locale: :en,
  allow_runtime_locale_download: false,
  supported_locales: [
    :en,
    :"zh-Hans",
    :hi,
    :es,
    :ar,
    :fr,
    :bn,
    :"pt-BR",
    :"pt-PT",
    :ru,
    :ur,
    :id,
    :de,
    :ja,
    :pcm,
    :mr,
    :te,
    :tr,
    :ta,
    :vi,
    :ko,
    :fil,
    :et,
    :fi,
    :sv
  ]


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

if config_env() in [:dev, :test] do
  config :covenant,
    contracts_dir: "contracts",
    test_paths: ["test/contract"],
    sibling_dir: false,
    results_dir: "_build/covenant/results"
end
