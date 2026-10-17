{ packages }:
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption mkIf types;
  cfg = config.services.audi;
  paths = import ./types.nix { inherit lib; };
  hostCertificate = import ./ssh-host-certificate.nix { inherit pkgs packages; inherit (cfg) caFile credentialFile; role = "audi"; origin = cfg.controlPlane; };
  dumps = import ./crash-dumps { inherit lib pkgs; };
  fleetOtelEnabled = lib.attrByPath [ "services" "overallsOtelFleet" "enable" ] false config;
  runtime = pkgs.writeText "audi-runtime.json" (builtins.toJSON ({
    version = 1;
    status_socket = "/run/audi/status.sock";
    control_plane = cfg.controlPlane;
    role = "gateway";
    host_id = cfg.hostId;
    connector_path = cfg.connectorPath;
    connector_uid = cfg.connectorUid;
    credential_file = "/run/audi/gateway.token";
    cacertfile = "/run/credentials/audi.service/ca.pem";
    host_key_dir = "/var/lib/audi/keys";
    bind = cfg.bindAddress;
    port = cfg.port;
  } // lib.optionalAttrs (cfg.publicOrigin != null) {
    public_origin = cfg.publicOrigin;
  } // lib.optionalAttrs cfg.tls.enable {
    tls = {
      zone = cfg.tls.zone;
      browser_origin = cfg.tls.browserOrigin;
      trust_file = "/run/credentials/audi.service/certificate-roots.pem";
      http_port = cfg.tls.httpPort;
      https_port = cfg.tls.httpsPort;
      trusted_proxy_peer = cfg.tls.trustedProxyPeer;
    } // lib.optionalAttrs (cfg.editorPackage != null) { editor_package = toString cfg.editorPackage; };
  }));
in {
  imports = [ ./crash-dumps/retention.nix (import ./audi-dns.nix { inherit packages; }) ];
  options.services.audi = {
    enable = mkEnableOption "Audi local guest SSH gateway";
    package = mkOption {
      type = types.package;
      default = if cfg.crashDumps.enable then packages.encrypted.audi else packages.audi;
      description = "Independent source-built Audi release.";
    };
    editorPackage = mkOption {
      type = types.nullOr types.package;
      default = packages.vscodeWeb;
      description = "Immutable browser editor release serving self-hosted webview bootstrap assets; must match the guest image and Marshall release admission.";
    };
    controlPlane = mkOption { type = types.str; description = "Verified HTTPS Marshall origin."; };
    publicOrigin = mkOption {
      type = types.nullOr types.str;
      default = if cfg.tls.enable then cfg.tls.browserOrigin else null;
      description = "Public Marshall HTTPS origin for SSH setup guidance; never the private control endpoint.";
    };
    hostId = mkOption { type = paths.uuid; description = "Enrolled identity of the local Lilly host."; };
    connectorPath = mkOption {
      type = types.addCheck paths.privatePath (value: builtins.stringLength value <= 107);
      default = "/run/lilly-ingress/audi.sock";
      description = "Restricted local Lilly Unix socket; no guest address is configured in Audi.";
    };
    connectorUid = mkOption {
      type = types.ints.between 0 4294967294;
      # Lilly runs unprivileged as its fixed service user (ADR-0182).
      default = if config.users.users ? lilly && config.users.users.lilly.uid != null
        then config.users.users.lilly.uid else 0;
      defaultText = lib.literalExpression "config.users.users.lilly.uid";
      description = "Expected Linux peer UID of the Lilly connector: the Lilly service user where Lilly runs.";
    };
    credentialFile = mkOption {
      type = paths.privatePath;
      description = "Private runtime file containing a separately provisioned Marshall gateway token.";
    };
    caFile = mkOption {
      type = paths.absolutePath;
      default = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      description = "CA certificates authenticating the Marshall HTTPS endpoint.";
    };
    bindAddress = mkOption { type = paths.ipv4; default = "0.0.0.0"; };
    port = mkOption { type = types.port; default = 22; };
    # @cc [owner:ghuntley,label:security] audi-administrative-access-mode
    # Physical-host defaults MUST retain administrative SSH on 2222. Explicit
    # console-only mode MUST forbid OpenSSH rather than create a root SSH path.
    administrativeAccess = mkOption {
      type = types.enum [ "openssh" "console" ];
      default = "openssh";
      description = "Administrative access path. Console-only deployments must disable administrative OpenSSH.";
    };
    openFirewall = mkOption { type = types.bool; default = false; };
    tls = {
      enable = mkEnableOption "Audi fleet wildcard TLS listener";
      zone = mkOption { type = types.str; description = "Delegated application DNS zone. Browser editor assets require at least two canonical lowercase DNS labels."; };
      browserOrigin = mkOption { type = types.str; description = "Public HTTPS Marshall browser origin for identity approval; separate from the private control API."; };
      certificateRootsFile = mkOption { type = paths.absolutePath;
        default = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"; };
      httpPort = mkOption { type = types.port; default = 80; };
      trustedProxyPeer = mkOption { type = types.nullOr paths.ipv4; default = null;
        description = "Inception parent gateway allowed to supply IPv4 PROXY metadata; null for public listeners."; };
      httpsPort = mkOption { type = types.port; default = 443; };
    };
    secretUnits = mkOption {
      type = types.listOf (types.strMatching "[a-zA-Z0-9_.@-]+\\.service");
      default = [];
      description = "Credential preparation services required before startup.";
    };
    cpuCores = mkOption { type = types.ints.positive; default = 2; };
    memoryMiB = mkOption { type = types.ints.positive; default = 1024; };
    crashDumps = dumps.options;
  };

  config = mkIf cfg.enable {
    assertions = [
      # @cc [owner:ghuntley,label:protocol;reliability] audi-module-editor-zone-boundary
      # Configured editor assets MUST use the same canonical multi-label zone
      # as the protocol and broker. Disabled TLS or editor assets retain the
      # existing generic gateway configuration boundary.
      { assertion = !cfg.tls.enable || cfg.editorPackage == null ||
          (builtins.stringLength cfg.tls.zone <= 189 &&
           builtins.length (lib.splitString "." cfg.tls.zone) >= 2 &&
           lib.all (label: builtins.match "[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?" label != null) (lib.splitString "." cfg.tls.zone));
        message = "Audi browser editor assets require a canonical zone with at least two DNS labels."; }
      { assertion = !cfg.tls.enable || cfg.tls.browserOrigin != cfg.controlPlane;
        message = "Audi browser origin must differ from its private Marshall machine API."; }
      { assertion = !cfg.tls.enable || builtins.length (lib.unique [ cfg.port cfg.tls.httpPort cfg.tls.httpsPort ]) == 3;
        message = "Audi SSH, HTTP and HTTPS must use distinct ports."; }
      { assertion = !(lib.attrByPath [ "services" "porsche" "enable" ] false config) || cfg.port != config.services.porsche.port
          || (cfg.bindAddress != "0.0.0.0" && config.services.porsche.bindAddress != "0.0.0.0"
            && cfg.bindAddress != config.services.porsche.bindAddress);
        message = "Audi and Porsche SSH listeners must not overlap in address and port."; }
      { assertion = cfg.port != 22 || cfg.administrativeAccess == "console" || (config.services.openssh.enable
          && builtins.elem 2222 config.services.openssh.ports
          && !builtins.elem 22 config.services.openssh.ports);
        message = "Audi on port 22 requires administrative OpenSSH on 2222 with port 22 removed."; }
      { assertion = cfg.administrativeAccess != "console" || !config.services.openssh.enable;
        message = "Console-only administration requires administrative OpenSSH to be disabled."; }
      { assertion = !config.services.openssh.enable || !builtins.elem cfg.port config.services.openssh.ports;
        message = "Audi and administrative OpenSSH must use distinct ports."; }
      { assertion = !cfg.crashDumps.enable || cfg.crashDumps.publicKeyFile != null;
        message = "Audi encrypted dumps require an operator public key file."; }
    ];
    users.groups.audi = {};
    users.users.audi = { isSystemUser = true; group = "audi"; };
    users.groups.overalls-otel-audi-ssh-source = lib.mkIf fleetOtelEnabled {};
    systemd.tmpfiles.rules = lib.optional fleetOtelEnabled
      "d /run/audi-ssh-slo 0750 audi overalls-otel-audi-ssh-source -";
    networking.firewall = mkIf cfg.openFirewall (import ./listener-firewall.nix {
      inherit lib config;
      address = cfg.bindAddress;
      tcpPorts = [ cfg.port ] ++ lib.optionals cfg.tls.enable [ cfg.tls.httpPort cfg.tls.httpsPort ];
    });
    services.overallsCrashDumpRetention.directories = lib.optional cfg.crashDumps.enable "/var/lib/audi-crash-dumps";
    systemd.coredump.settings.Coredump = mkIf cfg.crashDumps.enable { Storage = "none"; ProcessSizeMax = 0; };

    # @cc [owner:ghuntley,label:security] audi-service-custody
    # Audi MUST run as a dedicated unprivileged user, receive gateway secrets
    # through systemd credentials and keep a persistent host key separate from
    # administrative SSH. Restart MUST NOT replace an existing host key.
    systemd.services.audi-ssh-certificate = hostCertificate.service;
    systemd.timers.audi-ssh-certificate = hostCertificate.timer;
    systemd.services.audi = lib.mkMerge [ hostCertificate.startup {
      description = "Audi guest SSH gateway";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ] ++ cfg.secretUnits;
      requires = cfg.secretUnits;
      environment = {
        AUDI_CONFIG_FILE = runtime;
        RELEASE_TMP = "/run/audi";
        RELEASE_DISTRIBUTION = "none";
        ERL_CRASH_DUMP = "/dev/null";
        ERL_FLAGS = "+S ${toString cfg.cpuCores}:${toString cfg.cpuCores}";
      } // lib.optionalAttrs fleetOtelEnabled {
        AUDI_SLO_SNAPSHOT = "/run/audi-ssh-slo/slo.json";
        AUDI_SLO_SERVICE = "audi_ssh";
      };
      path = [ pkgs.openssh ];
      preStart = ''
        set -eu
        ${pkgs.coreutils}/bin/install -m 0400 "$CREDENTIALS_DIRECTORY/gateway.token" /run/audi/gateway.token
        ${pkgs.coreutils}/bin/mkdir -p -m 0700 /var/lib/audi/keys
        if ! test -e /var/lib/audi/keys/ssh_host_ed25519_key && ! test -L /var/lib/audi/keys/ssh_host_ed25519_key; then
          ${pkgs.coreutils}/bin/rm -f /run/audi/new-host-key /run/audi/new-host-key.pub
          ${pkgs.openssh}/bin/ssh-keygen -q -t ed25519 -N "" -f /run/audi/new-host-key
          ${pkgs.coreutils}/bin/mv /run/audi/new-host-key /var/lib/audi/keys/ssh_host_ed25519_key
          ${pkgs.coreutils}/bin/mv /run/audi/new-host-key.pub /var/lib/audi/keys/ssh_host_ed25519_key.pub
        fi
        ${hostCertificate.command}
      '';
      script = ''
        export RELEASE_COOKIE
        RELEASE_COOKIE="$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/basenc --base16 -w0)"
        exec ${dumps.launch cfg.crashDumps cfg.package "/var/lib/audi-crash-dumps" "${cfg.package}/bin/audi start"}
      '';
      serviceConfig = {
        Type = "exec";
        User = "audi";
        Group = if fleetOtelEnabled then "overalls-otel-audi-ssh-source" else "audi";
        SupplementaryGroups = lib.optionals fleetOtelEnabled [ "audi" ];
        UMask = "0077";
        LoadCredential = [ "gateway.token:${cfg.credentialFile}" "ca.pem:${cfg.caFile}" ]
          ++ lib.optionals cfg.tls.enable [ "certificate-roots.pem:${cfg.tls.certificateRootsFile}" ];
        StateDirectory = [ "audi" ] ++ lib.optional cfg.crashDumps.enable "audi-crash-dumps";
        StateDirectoryMode = "0700";
        RuntimeDirectory = [ "audi" ];
        RuntimeDirectoryMode = "0700";
        WorkingDirectory = cfg.package;
        ExecStopPost = lib.optional cfg.crashDumps.enable (dumps.finish "/var/lib/audi-crash-dumps");
        TimeoutStopSec = 30;
        KillMode = "control-group";
        CPUQuota = "${toString (cfg.cpuCores * 100)}%";
        MemoryMax = "${toString cfg.memoryMiB}M";
        LimitNOFILE = 65536;
        CapabilityBoundingSet = [ "CAP_NET_BIND_SERVICE" ];
        AmbientCapabilities = [ "CAP_NET_BIND_SERVICE" ];
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        # getifaddrs uses local Netlink to verify the configured probe address.
        # CAP_NET_ADMIN is absent; no IPv6 transport socket is permitted.
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_NETLINK" ];
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };
    } ];
  };
}
