{ packages }:
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption mkIf types;
  cfg = config.services.susan;
  paths = import ./types.nix { inherit lib; };
  # The Entra ID client for WNS (ADR-0236) is delivered only when a WNS app
  # id is configured, so bundles without Windows push need no WNS entries.
  secretNames = [
    "APNS_KEY_P8" "APNS_KEY_ID" "APNS_TEAM_ID" "FCM_SERVICE_ACCOUNT_JSON"
    "SUSAN_PUSH_KEY_SIGNING_KEY" "DATABASE_URL"
  ] ++ lib.optionals (cfg.wnsAppIds != [ ]) [ "WNS_TENANT_ID" "WNS_CLIENT_ID" "WNS_CLIENT_SECRET" ];
  limitType = types.submodule {
    options = {
      burst = mkOption { type = types.ints.between 1 100000; };
      per_hour = mkOption { type = types.ints.between 1 10000000; };
    };
  };
  runtime = pkgs.writeText "susan-public-config.json" (builtins.toJSON ({
    version = 1;
    bind = cfg.bind;
    port = cfg.port;
    trusted_proxies = cfg.trustedProxies;
    apns_topics = cfg.apnsTopics;
    fcm_app_ids = cfg.fcmAppIds;
  } // lib.optionalAttrs (cfg.wnsAppIds != [ ]) {
    wns_app_ids = cfg.wnsAppIds;
  } // lib.optionalAttrs (cfg.limits != { }) { limits = cfg.limits; }));
  releaseEnvironment = {
    SUSAN_CONFIG_FILE = "${runtime}";
    RELEASE_TMP = "/run/susan";
    RELEASE_DISTRIBUTION = "name";
    RELEASE_NODE = "susan@127.0.0.1";
    ERL_EPMD_ADDRESS = "127.0.0.1";
    ERL_CRASH_DUMP = "/dev/null";
    ERL_FLAGS = "+S ${toString cfg.cpuCores}:${toString cfg.cpuCores} -kernel inet_dist_use_interface {127,0,0,1}";
  };
  # Operator access is `bin/susan rpc` on the loopback distribution only;
  # Susan has no network admin surface (ADR-0224).
  operator = pkgs.writeShellScriptBin "susan-operator" ''
    set -eu
    if [ "$(${pkgs.coreutils}/bin/id -u)" != "$(${pkgs.coreutils}/bin/id -u susan)" ]; then
      exec ${pkgs.util-linux}/bin/setpriv --reuid=susan --regid=susan --init-groups "$0" "$@"
    fi
    export RELEASE_COOKIE
    RELEASE_COOKIE="$(${pkgs.coreutils}/bin/cat /var/lib/susan/cookie)"
    ${lib.concatStringsSep "\n" (lib.mapAttrsToList (name: value: "export ${name}=${lib.escapeShellArg value}") (releaseEnvironment // { RELEASE_TMP = "/tmp"; }))}
    cd ${cfg.package}
    exec ${cfg.package}/bin/susan rpc "$@"
  '';
in {
  options.services.susan = {
    enable = mkEnableOption "the Susan push relay for content-free Mila notifications (ADR-0224)";
    package = mkOption { type = types.package; default = packages.susan; description = "Susan OTP release."; };
    bind = mkOption { type = types.str; default = "127.0.0.1"; description = "Listener address behind the TLS-terminating proxy."; };
    port = mkOption { type = types.port; default = 4100; description = "Plain HTTP listener port; TLS terminates at the fronting proxy."; };
    trustedProxies = mkOption { type = types.listOf types.str; default = [ "127.0.0.1" ]; description = "Peers whose last X-Forwarded-For hop is believed for per-source rate limits."; };
    apnsTopics = mkOption { type = types.listOf types.str; default = [ ]; description = "Accepted APNs topics (Mila bundle identifiers)."; };
    fcmAppIds = mkOption { type = types.listOf types.str; default = [ ]; description = "Accepted FCM application identifiers."; };
    wnsAppIds = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Accepted WNS application identifiers (Mila's MSIX identity). Non-empty requires WNS_TENANT_ID, WNS_CLIENT_ID and WNS_CLIENT_SECRET in the secrets bundle.";
    };
    limits = mkOption {
      type = types.attrsOf limitType;
      default = { };
      description = "Optional token-bucket overrides keyed by key, install, source, global or issue.";
    };
    secretsFile = mkOption {
      type = paths.absolutePath;
      description = "SOPS document secrets/overalls-susan.enc.json with the six Susan secrets.";
    };
    secretUnits = mkOption { type = types.listOf (types.strMatching "[a-zA-Z0-9_.@-]+\\.service"); default = [ ]; };
    database.createLocally = mkOption {
      type = types.bool;
      default = true;
      description = "Create a local PostgreSQL database and peer-authenticated role named susan.";
    };
    cpuCores = mkOption { type = types.ints.positive; default = 2; };
    memoryMiB = mkOption { type = types.ints.positive; default = 1024; };
  };

  # @cc [owner:ghuntley,label:deployment;security] susan-service-custody
  # Susan MUST receive secrets only through the overallsSecrets bundle and
  # systemd credentials, run migrations as a separate release command before
  # start, expose distribution only on loopback for bin/susan rpc, and run
  # unprivileged with no writable state outside its own directories.
  config = mkIf cfg.enable {
    assertions = [
      { assertion = cfg.apnsTopics != [ ] || cfg.fcmAppIds != [ ] || cfg.wnsAppIds != [ ];
        message = "Susan requires at least one APNs topic, FCM application id or WNS application id."; }
      { assertion = lib.all (name: builtins.elem name [ "key" "install" "source" "global" "issue" ]) (builtins.attrNames cfg.limits);
        message = "Susan limit overrides must name key, install, source, global or issue."; }
    ];
    services.overallsSecrets.enable = true;
    services.overallsSecrets.bundles.susan = {
      encryptedFile = cfg.secretsFile;
      outputs = lib.genAttrs secretNames (name: { format = "raw"; secrets = [ name ]; });
    };
    services.susan.secretUnits = [ config.services.overallsSecrets.bundles.susan.unit ];

    services.postgresql = mkIf cfg.database.createLocally {
      enable = true;
      ensureDatabases = [ "susan" ];
      ensureUsers = [{ name = "susan"; ensureDBOwnership = true; }];
    };

    users.groups.susan = { };
    users.users.susan = { isSystemUser = true; group = "susan"; home = "/var/lib/susan"; };
    environment.systemPackages = [ operator ];

    systemd.services.susan = {
      description = "Susan push relay";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [ "network-online.target" ] ++ cfg.secretUnits
        ++ lib.optionals cfg.database.createLocally [ "postgresql.service" "postgresql-setup.service" ];
      requires = cfg.secretUnits ++ lib.optionals cfg.database.createLocally [ "postgresql.service" ];
      environment = releaseEnvironment;
      preStart = ''
        if [ ! -s /var/lib/susan/cookie ]; then
          ${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/basenc --base16 -w0 > /var/lib/susan/cookie.new
          ${pkgs.coreutils}/bin/chmod 0400 /var/lib/susan/cookie.new
          ${pkgs.coreutils}/bin/mv /var/lib/susan/cookie.new /var/lib/susan/cookie
        fi
        export RELEASE_COOKIE
        RELEASE_COOKIE="$(${pkgs.coreutils}/bin/cat /var/lib/susan/cookie)"
        RELEASE_DISTRIBUTION=none ${cfg.package}/bin/susan eval 'Susan.Release.migrate()'
      '';
      script = ''
        export RELEASE_COOKIE
        RELEASE_COOKIE="$(${pkgs.coreutils}/bin/cat /var/lib/susan/cookie)"
        exec ${cfg.package}/bin/susan start
      '';
      serviceConfig = {
        Type = "exec";
        User = "susan";
        Group = "susan";
        UMask = "0077";
        LoadCredential = map (name: "${name}:${config.services.overallsSecrets.bundles.susan.directory}/${name}") secretNames;
        RuntimeDirectory = "susan";
        RuntimeDirectoryMode = "0700";
        StateDirectory = "susan";
        StateDirectoryMode = "0700";
        WorkingDirectory = cfg.package;
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStartSec = 120;
        TimeoutStopSec = 30;
        KillMode = "control-group";
        CPUQuota = "${toString (cfg.cpuCores * 100)}%";
        MemoryMax = "${toString cfg.memoryMiB}M";
        LimitNOFILE = 65536;
        CapabilityBoundingSet = [ ];
        NoNewPrivileges = true;
        PrivateDevices = true;
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ProtectKernelTunables = true;
        ProtectKernelModules = true;
        ProtectControlGroups = true;
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
        RestrictSUIDSGID = true;
        LockPersonality = true;
      };
    };
  };
}
