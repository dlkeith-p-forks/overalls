{ config, lib, pkgs, ... }:
let
  fleet = config.services.overallsOtelFleet;
  store = lib.attrByPath [ "services" "overallsLogStore" ] { enable = false; } config;
  enabled = fleet.enable && fleet.role == "central" && store.enable;
in {
  # @cc [owner:ghuntley,label:security] grafana-log-reader-authority
  # Grafana MUST use verified fleet-entry TLS and reader-only credentials loaded
  # by systemd. Neither the insert authority nor a plaintext password may enter
  # its Nix configuration, browser queries or command arguments.
  config = lib.mkIf enabled {
    services.grafana.declarativePlugins = [ pkgs.grafanaPlugins.victoriametrics-logs-datasource ];
    services.grafana.provision.datasources.settings.datasources = [{
      name = "VictoriaLogs"; uid = "overalls-victorialogs"; type = "victoriametrics-logs-datasource";
      access = "proxy"; url = "https://logs.fleet.internal:${toString store.port}";
      editable = false; basicAuth = true; basicAuthUser = "reader";
      jsonData = {
        tlsSkipVerify = false; tlsAuthWithCACert = true;
        serverName = "logs.fleet.internal"; maxLines = "500";
        derivedFields = [{
          name = "TraceID"; matcherType = "label"; matcherRegex = "^trace_id$";
          datasourceUid = "overalls-tempo"; url = "$\${__value.raw}"; urlDisplayLabel = "Open trace";
        }];
      };
      secureJsonData = {
        basicAuthPassword = "$__file{/run/credentials/grafana.service/logstore-reader.password}";
        tlsCACert = "$__file{/run/credentials/grafana.service/logstore-ca.crt}";
      };
    }];
    systemd.services.grafana = {
      after = store.secretUnits;
      requires = store.secretUnits;
      serviceConfig.LoadCredential = [
        "logstore-reader.password:${store.readerPasswordFile}"
        "logstore-ca.crt:/etc/overalls/logstore-ca.crt"
      ];
    };
  };
}
