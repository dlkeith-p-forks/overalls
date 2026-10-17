{ packages }:
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption mkIf types;
  cfg = config.services.brady;
  paths = import ../types.nix { inherit lib; };
  lilly = config.services.lilly;
  suffix = builtins.substring 0 12 (builtins.hashString "sha256" lilly.hostId);
  selected = lib.findFirst (pool: pool.id == cfg.poolId) null lilly.pools;
  zpool = if selected == null then "invalid" else builtins.head (lib.splitString "/" selected.storage.dataset);
  dataset = "${zpool}/brady-${suffix}";
  storage = pkgs.writeText "brady-storage.json" (builtins.toJSON {
    pool = selected; inherit dataset;
    host_id = lilly.hostId;
    zfs = "${config.boot.zfs.package}/bin/zfs";
    zpool = "${config.boot.zfs.package}/bin/zpool";
  });
  runtime = pkgs.writeText "brady-runtime.json" (builtins.toJSON {
    version = 1; host_id = lilly.hostId;
    issuer_cert_file = "/run/brady/credentials/issuer.pem";
    issuer_key_file = "/run/brady/credentials/issuer.key";
    upstream_ca_file = cfg.upstreamCAFile;
    protected_cidrs = lilly.protectedCidrs;
    tls_exceptions = cfg.tlsExceptions;
    cache_directory = "/var/cache/brady";
    cache_dataset = dataset;
    # Upper bound; fresh native observations further constrain quota and headroom.
    cache_quota_bytes = 274877906944;
  });
  resolv = pkgs.writeText "brady-resolv.conf" (lib.concatMapStrings (ip: "nameserver ${ip}\n") cfg.dnsResolvers);
  otelEnabled = lib.attrByPath [ "services" "overallsOtelFleet" "enable" ] false config;
in {
  options.services.brady = {
    enable = mkEnableOption "native transparent Firecracker HTTP/HTTPS cache";
    package = mkOption { type = types.package; default = packages.brady; };
    poolId = mkOption { type = types.nullOr paths.uuid; default = if lilly.pools == [] then null else (builtins.head lilly.pools).id; };
    issuerCertificateFile = mkOption { type = paths.privatePath; description = "Runtime signing CA certificate; Brady does not provision the CA."; };
    issuerKeyFile = mkOption { type = paths.privatePath; description = "Runtime signing CA key."; };
    upstreamCAFile = mkOption { type = paths.absolutePath; default = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"; };
    httpPorts = mkOption { type = types.listOf types.port; default = [ 80 ]; };
    httpsPorts = mkOption { type = types.listOf types.port; default = [ 443 ]; };
    dnsResolvers = mkOption { type = types.listOf (types.strMatching "[0-9]+\\.[0-9]+\\.[0-9]+\\.[0-9]+"); default = [ "1.1.1.1" "8.8.8.8" ]; };
    tlsExceptions = mkOption { type = types.listOf (types.submodule { options = {
      host = mkOption { type = types.strMatching "[a-z0-9][a-z0-9.-]{0,252}"; };
      port = mkOption { type = types.port; default = 443; };
    }; }); default = []; };
    secretUnits = mkOption { type = types.listOf (types.strMatching "[a-zA-Z0-9_.@-]+\\.service"); default = []; };
  };
  config = mkIf cfg.enable {
    assertions = [
      { assertion = lilly.enable && selected != null; message = "Brady requires local Lilly and a configured native ZFS pool."; }
      { assertion = cfg.httpPorts != [] && cfg.httpsPorts != [] && builtins.length cfg.httpPorts <= 32 && builtins.length cfg.httpsPorts <= 32
          && builtins.length (lib.unique (cfg.httpPorts ++ cfg.httpsPorts)) == builtins.length (cfg.httpPorts ++ cfg.httpsPorts);
        message = "Brady web ports must be bounded, unique and disjoint."; }
      { assertion = builtins.length cfg.dnsResolvers >= 1 && builtins.length cfg.dnsResolvers <= 8 && builtins.length cfg.tlsExceptions <= 256;
        message = "Brady DNS and TLS exceptions must remain bounded."; }
    ];
    users.groups.brady = {};
    systemd.tmpfiles.rules = [ "d /run/lilly-brady 0750 root brady - -" ];
    users.users.brady = { isSystemUser = true; group = "brady"; };
    boot.kernelModules = [ "nf_tproxy_ipv4" "nft_tproxy" ];
    systemd.services.brady-storage = {
      description = "Prepare disposable Brady ZFS cache";
      before = [ "brady.service" ];
      after = [ "lilly.service" ];
      unitConfig.RequiresMountsFor = lib.optional (selected != null) selected.path;
      serviceConfig = {
        Type = "oneshot"; RemainAfterExit = true;
        ExecStart = "${pkgs.python3}/bin/python ${./storage.py} ${storage}";
        TimeoutStartSec = 120; UMask = "0077";
      };
    };
    systemd.services.brady-pressure = {
      description = "Publish bounded native Brady ZFS pressure observations";
      after = [ "brady-storage.service" ];
      wants = [ "brady-storage.service" ];
      serviceConfig = {
        ExecStart = "${pkgs.python3}/bin/python ${./storage.py} ${storage} observe";
        Restart = "always"; RestartSec = 5;
        User = "root"; Group = "brady"; UMask = "0027";
        RuntimeDirectory = "brady-pressure"; RuntimeDirectoryMode = "0750";
        NoNewPrivileges = true; ProtectSystem = "strict"; ProtectHome = true; PrivateTmp = true;
        # ZFS reports the namespace mount's readonly flag. Preserve the native
        # dataset flags so read-only inspection does not mistake ProtectSystem's
        # remount for a host storage-policy change. The helper only queries ZFS.
        ReadWritePaths = [ "/var/cache/brady" ] ++ lib.optional (selected != null) selected.path;
        CapabilityBoundingSet = [ "CAP_SYS_ADMIN" "CAP_DAC_READ_SEARCH" ];
        # The one-second native sampler must complete within the three-second admission deadline.
        MemoryMax = "64M"; CPUQuota = "100%"; TasksMax = 16;
      };
    };
    systemd.services.brady = {
      description = "Brady transparent guest egress proxy";
      wantedBy = [ "multi-user.target" ];
      wants = [ "lilly.service" "brady-storage.service" "brady-pressure.service" ];
      after = [ "lilly.service" "brady-storage.service" ] ++ cfg.secretUnits;
      requires = cfg.secretUnits;
      startLimitIntervalSec = 0;
      environment = {
        BRADY_CONFIG_FILE = runtime;
        RELEASE_DISTRIBUTION = "none"; RELEASE_TMP = "/run/brady"; ERL_CRASH_DUMP = "/dev/null";
      } // lib.optionalAttrs otelEnabled {
        BRADY_FLEET_MONITOR = "1";
        BRADY_SLO_EXPORT = "1";
      };
      preStart = ''
        ${pkgs.coreutils}/bin/mkdir -p -m 0700 /run/brady/credentials
        for credential in issuer.pem issuer.key; do
          ${pkgs.coreutils}/bin/install -m 0400 "$CREDENTIALS_DIRECTORY/$credential" "/run/brady/credentials/$credential"
        done
      '';
      script = ''
        export RELEASE_COOKIE
        RELEASE_COOKIE="$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/basenc --base16 -w0)"
        exec ${cfg.package}/bin/brady start
      '';
      serviceConfig = {
        Type = "exec"; User = "brady"; Group = "brady"; UMask = "0077";
        Restart = "always"; RestartSec = 5;
        RuntimeDirectory = "brady"; RuntimeDirectoryMode = "0700";
        LoadCredential = [ "issuer.pem:${cfg.issuerCertificateFile}" "issuer.key:${cfg.issuerKeyFile}" ];
        NetworkNamespacePath = "/run/netns/lilly-${suffix}";
        BindReadOnlyPaths = [ "${resolv}:/etc/resolv.conf" ];
        CapabilityBoundingSet = [ "CAP_NET_RAW" ];
        AmbientCapabilities = [ "CAP_NET_RAW" ];
        NoNewPrivileges = true; ProtectSystem = "strict"; ProtectHome = true; PrivateTmp = true;
        ReadWritePaths = [ "-/var/cache/brady" ];
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" ];
        MemoryMax = "1G"; CPUQuota = "200%"; TasksMax = 1024;
        CPUAccounting = true; MemoryAccounting = true; IOAccounting = true;
      };
    };
  };
}
