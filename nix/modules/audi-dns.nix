{ packages }:
{ config, lib, pkgs, ... }:
let
  cfg = config.services.audiDns;
  fleetOtelEnabled = lib.attrByPath [ "services" "overallsOtelFleet" "enable" ] false config;
  paths = import ./types.nix { inherit lib; };
  name = lib.types.strMatching "[a-z0-9][a-z0-9.-]*";
  runtime = pkgs.writeText "audi-dns-runtime.json" (builtins.toJSON {
    version = 1;
    status_socket = "/run/audi-dns/status.sock";
    role = "dns";
    control_plane = cfg.controlPlane;
    credential_file = "/run/audi-dns/dns.token";
    cacertfile = "/run/credentials/audi-dns.service/ca.pem";
    inherit (cfg) zone nameservers mailbox port;
    bind = cfg.bindAddress;
  });
in {
  options.services.audiDns = {
    enable = lib.mkEnableOption "Audi authoritative DNS";
    package = lib.mkOption { type = lib.types.package; default = packages.audi; };
    controlPlane = lib.mkOption { type = lib.types.str; description = "Verified HTTPS Marshall origin."; };
    credentialFile = lib.mkOption { type = paths.privatePath; description = "Private runtime file containing a separately enrolled DNS service token."; };
    caFile = lib.mkOption { type = paths.absolutePath; default = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"; };
    secretUnits = lib.mkOption { type = lib.types.listOf (lib.types.strMatching "[a-zA-Z0-9_.@-]+\\.service"); default = []; };
    zone = lib.mkOption { type = name; description = "Delegated application zone."; };
    nameservers = lib.mkOption { type = lib.types.listOf name; description = "At least two independent authoritative nameservers."; };
    mailbox = lib.mkOption { type = name; description = "SOA responsible mailbox in DNS name form."; };
    bindAddress = lib.mkOption { type = paths.ipv4; default = "0.0.0.0"; };
    port = lib.mkOption { type = lib.types.port; default = 53; };
    openFirewall = lib.mkOption { type = lib.types.bool; default = false; };
    cpuCores = lib.mkOption { type = lib.types.ints.positive; default = 2; };
    memoryMiB = lib.mkOption { type = lib.types.ints.positive; default = 512; };
  };
  config = lib.mkIf cfg.enable {
    assertions = [{
      assertion = builtins.length cfg.nameservers >= 2 && builtins.length cfg.nameservers <= 8
        && lib.unique cfg.nameservers == cfg.nameservers;
      message = "Audi DNS requires two to eight distinct authoritative nameservers.";
    }];
    users.groups.audi-dns = {};
    users.users.audi-dns = { isSystemUser = true; group = "audi-dns"; };
    networking.firewall = lib.mkIf cfg.openFirewall (import ./listener-firewall.nix {
      inherit lib config; address = cfg.bindAddress;
      tcpPorts = [ cfg.port ]; udpPorts = [ cfg.port ];
    });

    # @cc [owner:ghuntley,label:security] audi-dns-service-boundary
    # DNS MUST run without gateway keys or Lilly privileges. Its only capability
    # is binding a privileged port. No static configuration may inject routes;
    # an empty or stale replica MUST fail closed until authenticated publication.
    systemd.services.audi-dns = {
      description = "Audi authoritative DNS";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ] ++ cfg.secretUnits;
      requires = cfg.secretUnits;
      environment = {
        AUDI_CONFIG_FILE = runtime;
        RELEASE_TMP = "/run/audi-dns";
        RELEASE_DISTRIBUTION = "none";
        ERL_CRASH_DUMP = "/dev/null";
        ERL_FLAGS = "+S ${toString cfg.cpuCores}:${toString cfg.cpuCores}";
      } // lib.optionalAttrs fleetOtelEnabled {
        AUDI_SLO_SNAPSHOT = "/run/audi-dns/slo.json";
        AUDI_SLO_SERVICE = "audi_dns";
      };
      script = ''
        ${pkgs.coreutils}/bin/install -m 0600 "$CREDENTIALS_DIRECTORY/dns.token" /run/audi-dns/dns.token
        export RELEASE_COOKIE
        RELEASE_COOKIE="$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/basenc --base16 -w0)"
        exec ${cfg.package}/bin/audi start
      '';
      serviceConfig = {
        Type = "exec";
        User = "audi-dns";
        Group = "audi-dns";
        UMask = "0077";
        RuntimeDirectory = "audi-dns";
        RuntimeDirectoryMode = "0700";
        LoadCredential = [ "dns.token:${cfg.credentialFile}" "ca.pem:${cfg.caFile}" ];
        WorkingDirectory = cfg.package;
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStopSec = 30;
        KillMode = "control-group";
        CPUQuota = "${toString (cfg.cpuCores * 100)}%";
        MemoryMax = "${toString cfg.memoryMiB}M";
        LimitNOFILE = 4096;
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
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" ];
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };
    };
    # @cc [owner:ghuntley,label:security;reliability] audi-dns-exporter-custody
    # The exporter MUST read only the Audi DNS-owned numeric snapshot and
    # connect through its DNS-only Unix collector group. Ordinary Audi DNS
    # processes MUST NOT gain that group; exporter loss MUST NOT stop DNS.
  };
}
