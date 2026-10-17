import Config

# The collector reads only this private, fixed-path projection. systemd supplies
# the service incarnation; no credential or request field is read from its env.
if System.get_env("BRADY_FLEET_MONITOR") == "1" do
  invocation = System.get_env("INVOCATION_ID", "")

  # Missing monitoring identity leaves observations unknown; it must not prevent
  # the proxy from starting or publish counters under an invented service owner.
  if Regex.match?(~r/\A[0-9a-f]{32}\z/, invocation) do
    config :brady, :metrics,
      path: "/run/brady/metrics.json",
      slo_path: if(System.get_env("BRADY_SLO_EXPORT") == "1", do: "/run/brady/slo.json"),
      cache: Brady.Cache.Store,
      invocation: invocation
  end
end

case System.get_env("BRADY_CONFIG_FILE") do
  nil ->
    if config_env() == :prod, do: raise("Brady runtime configuration is required")

  path ->
    config :brady, :config_file, path
end
