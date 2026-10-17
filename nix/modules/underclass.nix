{ packages }:
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkEnableOption mkIf mkOption types;
  cfg = config.services.underclass;
  localTypes = import ./types.nix { inherit lib; };
  tailscale = config.services.tailscale;
  tailscaleExe = lib.getExe tailscale.package;
  localOrigin = "http://127.0.0.1:${toString cfg.port}";
  otelEnabled = lib.attrByPath [ "services" "overallsOtelFleet" "enable" ] false config;
  otelProbe = pkgs.callPackage ./otel-guest/receiver.nix {};
in
{
  options.services.underclass = {
    enable = mkEnableOption "independent host-local Underclass subscription pool";
    package = mkOption {
      type = types.package;
      default = packages.underclass;
      description = "Pinned Underclass package.";
    };
    port = mkOption {
      type = types.port;
      default = 8080;
      description = "Loopback HTTP port. Underclass is never bound directly to a fleet interface.";
    };
    environmentFile = mkOption {
      type = localTypes.privatePath;
      default = "/run/overalls-secrets/underclass/environment";
      description = "Runtime environment file containing UNDERCLASS_PROXY_KEY and UNDERCLASS_UI_TOKEN.";
    };
    secretUnits = mkOption {
      type = types.listOf (types.strMatching "[a-zA-Z0-9_.@-]+\\.service");
      default = [ ];
      description = "Secret preparation units required before Underclass starts.";
    };
    tailscaleServe = {
      enable = mkOption {
        type = types.bool;
        default = true;
        description = "Publish the loopback service through tailnet-only Tailscale Serve HTTPS.";
      };
      httpsPort = mkOption {
        type = types.port;
        default = 443;
        description = "Tailnet HTTPS port reserved for Underclass on this host.";
      };
    };
  };

  config = mkIf cfg.enable {
    # @cc [owner:ghuntley,label:cli] underclass-commands-on-path
    # Enabling Underclass MUST put its configured package on the host PATH.
    environment.systemPackages = [ cfg.package ];

    assertions = [
      {
        assertion = !cfg.tailscaleServe.enable || tailscale.enable;
        message = "Underclass Tailscale Serve publication requires services.tailscale.enable.";
      }
    ];

    # @cc [owner:ghuntley,label:security] underclass-loopback-secrets
    # Underclass MUST listen only on loopback and receive its API/admin keys from
    # a private runtime file. Neither key may enter the Nix store or command line.

    # @cc [owner:ghuntley,label:security] underclass-credential-separation
    # Proxy and administrative credentials MUST both be present and distinct;
    # each credential MUST be rejected at the other authorization boundary.
    systemd.services.underclass = {
      description = "Independent host-local Underclass subscription pool";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ] ++ cfg.secretUnits;
      requires = cfg.secretUnits;
      environment = {
        UNDERCLASS_DATA_DIR = "/var/lib/underclass";
        UNDERCLASS_MONITOR_SOCKET = "/run/underclass/monitor.sock";
        RUST_LOG = "info";
      } // lib.optionalAttrs otelEnabled {
        UNDERCLASS_SLO_SNAPSHOT = "/run/underclass/slo/slo.json";
      };
      # @cc [owner:ghuntley,label:security] underclass-local-monitor-socket
      # Only the limited monitor endpoint MAY be readable without a token on
      # the host-local Unix socket. Network administration retains its token.
      serviceConfig = {
        ExecStartPre = "${pkgs.runtimeShell} -ec 'test -n \"$UNDERCLASS_PROXY_KEY\"; test -n \"$UNDERCLASS_UI_TOKEN\"; test \"$UNDERCLASS_PROXY_KEY\" != \"$UNDERCLASS_UI_TOKEN\"'";
        ExecStart = "${lib.getExe cfg.package} serve --bind 127.0.0.1:${toString cfg.port}";
        EnvironmentFile = cfg.environmentFile;
        DynamicUser = true;
        Group = lib.mkIf otelEnabled "overalls-otel-underclass-source";
        StateDirectory = "underclass";
        StateDirectoryMode = "0700";
        RuntimeDirectory = "underclass";
        RuntimeDirectoryMode = "0755";
        UMask = "0077";
        Restart = "always";
        RestartSec = 5;
        TimeoutStopSec = 30;
        MemoryMax = "1G";
        CPUQuota = "200%";
        TasksMax = 512;
        LimitNOFILE = 8192;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        ProtectClock = true;
        ProtectHostname = true;
        ProtectKernelLogs = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" ];
        RestrictNamespaces = true;
        RestrictRealtime = true;
        RestrictSUIDSGID = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
        RemoveIPC = true;
        SystemCallArchitectures = "native";
      };
    };

    users.groups.overalls-otel-underclass-source = lib.mkIf otelEnabled {};
    users.users.otel-underclass-exporter = lib.mkIf otelEnabled {
      isSystemUser = true;
      group = "overalls-otel-underclass-source";
    };

    # @cc [owner:ghuntley,label:security;reliability] underclass-isolated-outcome-export
    # The exporter MUST have a separate UID, read only the source-group numeric
    # snapshot and write only its collector intake. Private provider state,
    # environment credentials and producer process data MUST remain inaccessible.
    systemd.services.underclass-proxy-slo-exporter = lib.mkIf otelEnabled {
      description = "Export durable Underclass proxy completion metrics";
      wantedBy = [ "multi-user.target" ];
      after = [ "underclass.service" "opentelemetry-collector.service" ];
      requires = [ "underclass.service" ];
      partOf = [ "underclass.service" ];
      serviceConfig = {
        Type = "exec";
        ExecStart = "${otelProbe}/bin/slo_exporter underclass_proxy /run/underclass/slo/slo.json /run/overalls-otel-underclass-proxy/collector.sock";
        User = "otel-underclass-exporter";
        Group = "overalls-otel-underclass-source";
        SupplementaryGroups = [ "overalls-otel-underclass-proxy" ];
        InaccessiblePaths = [ cfg.environmentFile "-/var/lib/underclass" "-/var/lib/private/underclass" "-/run/overalls-secrets" ];
        ProtectProc = "invisible";
        ProcSubset = "pid";
        Restart = "always";
        RestartSec = 5;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        MemoryMax = "64M";
        CPUQuota = "10%";
        TasksMax = 8;
      };
    };

    # @cc [owner:ghuntley,label:security;reliability] underclass-local-readiness-probe
    # The independent probe MUST retain no Underclass credentials and MUST
    # report a local monitor refusal as zero while collector loss remains absent.
    systemd.services.underclass-monitor-probe = lib.mkIf otelEnabled {
      description = "Probe Underclass local monitor for candidate readiness";
      wantedBy = [ "multi-user.target" ];
      after = [ "underclass.service" "opentelemetry-collector.service" ];
      serviceConfig = {
        Type = "exec";
        ExecStart = "${otelProbe}/bin/underclass_probe /run/underclass/monitor.sock /run/overalls-otel-underclass/collector.sock";
        User = "overalls-otel-underclass-probe";
        Group = "overalls-otel-underclass";
        Restart = "always";
        RestartSec = 5;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        MemoryMax = "64M";
        CPUQuota = "10%";
        TasksMax = 8;
      };
    };

    # @cc [owner:ghuntley,label:security] underclass-tailnet-only
    # Remote Underclass traffic MUST terminate at a systemd-supervised foreground
    # Tailscale Serve process and proxy to loopback. Funnel, detached publication
    # and direct fleet-interface listeners MUST NOT be enabled.
    systemd.services.underclass-tailscale-serve = mkIf cfg.tailscaleServe.enable {
      description = "Publish Underclass privately through Tailscale Serve";
      wantedBy = [ "multi-user.target" ];
      after = [ "tailscaled.service" "underclass.service" ];
      requires = [ "tailscaled.service" "underclass.service" ];
      serviceConfig = {
        Type = "exec";
        ExecStart = "${tailscaleExe} serve --yes --https=${toString cfg.tailscaleServe.httpsPort} ${localOrigin}";
        TimeoutStartSec = 60;
        TimeoutStopSec = 30;
        Restart = "always";
        RestartSec = 10;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        PrivateTmp = true;
        PrivateDevices = true;
        RestrictAddressFamilies = [ "AF_UNIX" ];
        RestrictNamespaces = true;
        LockPersonality = true;
        MemoryDenyWriteExecute = true;
      };
    };
  };
}
