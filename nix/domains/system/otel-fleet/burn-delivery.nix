{ config, lib, pkgs, ... }:
let
  fleet = config.services.overallsOtelFleet;
  cfg = fleet.burnAlerts;
  objectives = import ./objectives.nix { hosts = fleet.roster; };
  runtimePath = value: value == null || (lib.hasPrefix "/" value && !lib.hasPrefix "/nix/store/" value);
in {
  options.services.overallsOtelFleet.burnAlerts = {
    enable = lib.mkEnableOption "private Alertmanager delivery of provisional seven-day burn warnings";
    webhookUrlFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Private runtime file containing the approved HTTPS webhook URL; no plaintext URL enters Nix configuration.";
    };
    bearerTokenFile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Optional private runtime bearer credential for the approved webhook.";
    };
  };

  # @cc [owner:ghuntley,label:security;reliability] fleet-burn-delivery-boundary
  # Delivery MUST require explicit central-host enablement and runtime secrets.
  # Only the fixed provisional burn roster MAY reach the webhook; unrelated
  # alerts MUST have no receiver. No listener or cluster port may be public.
  config = lib.mkIf cfg.enable {
    assertions = [
      { assertion = fleet.enable && fleet.role == "central";
        message = "Burn notification delivery requires central fleet telemetry."; }
      { assertion = cfg.webhookUrlFile != null && runtimePath cfg.webhookUrlFile && runtimePath cfg.bearerTokenFile;
        message = "Burn notification credentials require absolute runtime files outside the Nix store."; }
    ];
    services.prometheus.alertmanagers = [{
      static_configs = [{ targets = [ "127.0.0.1:9093" ]; }];
    }];
    services.prometheus.scrapeConfigs = [{
      job_name = "fleet-burn-delivery";
      static_configs = [{ targets = [ "127.0.0.1:9093" ]; }];
    }];
    services.prometheus.alertmanager = {
      enable = true;
      listenAddress = "127.0.0.1";
      port = 9093;
      openFirewall = false;
      extraFlags = [ "--cluster.listen-address=" ];
      # The upstream schema checker accepts private file references without
      # reading their contents. Retain both build and startup validation.
      checkConfig = true;
      configuration = {
        route = {
          receiver = "unrouted";
          group_by = [ "alertname" "slo" "window" ];
          group_wait = "30s";
          group_interval = "5m";
          repeat_interval = "4h";
          routes = builtins.concatMap (source: builtins.map (window: {
            receiver = "fleet-burn";
            matchers = [
              "alertname=\"OverallsSLOBurn_${window}_${source.id}\""
              "slo=\"${source.id}\"" "window=\"${window}\""
              "status=\"provisional\"" "severity=\"warning\""
            ];
          }) [ "fast" "slow" ]) objectives;
        };
        receivers = [ { name = "unrouted"; } {
          name = "fleet-burn";
          webhook_configs = [{
            url_file = "/run/credentials/alertmanager.service/webhook-url";
            send_resolved = true;
            max_alerts = 40;
            http_config = {
              follow_redirects = false;
            } // lib.optionalAttrs (cfg.bearerTokenFile != null) {
              authorization = {
                type = "Bearer";
                credentials_file = "/run/credentials/alertmanager.service/webhook-token";
              };
            };
          }];
        } ];
      };
    };
    systemd.services.alertmanager = {
      # @cc [owner:ghuntley,label:security] burn-secret-safe-startup
      # Non-HTTPS destinations and malformed configuration MUST refuse startup without printing
      # URL or credential bytes. Delivery errors MUST NOT enter fleet logs.
      serviceConfig = {
        LoadCredential = [ "webhook-url:${if cfg.webhookUrlFile == null then "/run/overalls-missing-webhook-url" else cfg.webhookUrlFile}" ]
          ++ lib.optional (cfg.bearerTokenFile != null) "webhook-token:${cfg.bearerTokenFile}";
        RestrictAddressFamilies = lib.mkForce [ "AF_INET" "AF_UNIX" "AF_NETLINK" ];
        StandardOutput = "null";
        StandardError = "null";
        MemoryMax = "256M";
        TasksMax = 64;
        ExecStartPre = lib.mkAfter [
          "${pkgs.prometheus-alertmanager}/bin/amtool check-config /tmp/alert-manager-substituted.yaml"
        ];
      };
      preStart = ''
        ${pkgs.gnugrep}/bin/grep -Eq '^https://[^[:space:]]+$' "$CREDENTIALS_DIRECTORY/webhook-url" || exit 1
      '';
    };
  };
}
