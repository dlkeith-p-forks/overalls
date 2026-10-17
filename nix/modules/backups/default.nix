{ packages }:
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption mkIf types;
  cfg = config.services.overallsBackups;
  paths = import ../types.nix { inherit lib; };
  enabled = name: lib.attrByPath [ "services" name "enable" ] false config;
  lilly = config.services.lilly;
  marshall = config.services.marshall;
  scripts = pkgs.runCommand "overalls-backup-runtime" {} ''
    mkdir -p $out
    cp ${./common.py} $out/common.py
    cp ${./schema.py} $out/schema.py
    cp ${./host.py} $out/host.py
    cp ${./journal.py} $out/journal.py
    cp ${./postgres.py} $out/postgres.py
    cp ${./restic.py} $out/restic.py
    cp ${./runtime.py} $out/runtime.py
  '';
  lillyConfig = pkgs.writeText "overalls-lilly-backup.json" (builtins.toJSON {
    host_id = lilly.hostId;
    pools = lilly.pools;
    vm_state_directory = lilly.vmStateDirectory;
    minimum_free_bytes = cfg.minimumFreeBytes;
  });
  lillyTool = pkgs.writeShellScript "overalls-lilly-backup" ''
    set -eu
    export PATH="${packages.lilly}/host-tools/bin:$PATH"
    export RELEASE_DISTRIBUTION=none RELEASE_TMP=/run/overalls-backups/release ERL_CRASH_DUMP=/dev/null ERL_FLAGS='+S 2:2'
    export RELEASE_COOKIE
    RELEASE_COOKIE="$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/basenc --base16 -w0)"
    export OVERALLS_BACKUP_CONFIG=${lillyConfig}
    export OVERALLS_BACKUP_OPERATION="$1" OVERALLS_BACKUP_REQUEST="$2"
    ${pkgs.coreutils}/bin/mkdir -p "$RELEASE_TMP"
    exec ${packages.lilly}/bin/lilly eval 'Lilly.Backup.main()'
  '';
  hostFiles = lib.filter (path: builtins.hasAttr path config.environment.etc)
    [ "overalls-host.json" "overalls-installation.json" "overalls/service-ca.crt" ];
  defaultPaths = [ "/etc/machine-id" ]
    ++ lib.optionals config.services.openssh.enable (lib.concatMap (key: [ key.path "${key.path}.pub" ]) config.services.openssh.hostKeys)
    ++ map (path: "/etc/${path}") hostFiles
    ++ lib.optional (config.services.overallsAutoUpdate.enable or false) "/var/lib/overalls-host"
    ++ lib.optionals (enabled "lilly") ([ lilly.stateDirectory lilly.vmStateDirectory lilly.networkStateDirectory ]
      ++ lib.optional (enabled "lillyTransfer") config.services.lillyTransfer.stateDirectory)
    ++ lib.optional (enabled "porsche") "/var/lib/porsche/keys"
    ++ lib.optionals (enabled "audi") [ "/var/lib/audi/keys" ]
    ++ lib.optionals (lib.attrByPath [ "services" "marshallProxy" "acme" "enable" ] false config) [ "/var/lib/acme" "/var/lib/overalls-certificates" ]
    ++ lib.optional (enabled "ziggy") "/var/lib/ziggy/spool"
    ++ lib.optional (enabled "underclass") "/var/lib/underclass";
  ciphertext = map (bundle: bundle.encryptedFile) (builtins.attrValues (config.services.overallsSecrets.bundles or {}));
  recoveryConfig = pkgs.writeText "overalls-backup-recovery.json" (builtins.toJSON {
    version = 1;
    hostname = config.networking.hostName;
    host_id = config.networking.hostId;
    revision = config.system.configurationRevision or null;
    services = lib.genAttrs [ "marshall" "lilly" "porsche" "audi" "ziggy" "galileo" "underclass" ] enabled;
    images = lib.optionals (enabled "lilly") (map (image: image.path) lilly.images);
    pools = lib.optionals (enabled "lilly") lilly.pools;
  });
  descriptor = pkgs.writeText "overalls-backups.json" (builtins.toJSON {
    hostname = config.networking.hostName;
    repository = "s3:${cfg.s3.endpoint}/${cfg.s3.bucket}/${cfg.s3.prefix}/${config.networking.hostName}";
    region = cfg.s3.region;
    password_file = cfg.passwordFile;
    cache_directory = "/var/cache/overalls-backups";
    state_directory = "/var/lib/overalls-backups";
    revision = config.system.configurationRevision or null;
    restic = "${cfg.package}/bin/restic";
    zfs = "${pkgs.zfs}/bin/zfs";
    findmnt = "${pkgs.util-linux}/bin/findmnt";
    mount = "${pkgs.util-linux}/bin/mount";
    umount = "${pkgs.util-linux}/bin/umount";
    command_timeout = cfg.commandTimeoutSeconds;
    upload_limit_kib = cfg.uploadLimitKiB;
    keep_last = cfg.retention.keepLast;
    initialize = cfg.initialize;
    paths = lib.unique ((lib.optionals cfg.defaults.enable defaultPaths) ++ cfg.extraPaths);
    materialize = [ recoveryConfig ] ++ lib.optionals cfg.defaults.enable ciphertext;
    images = lib.optionals (cfg.defaults.enable && enabled "lilly") (map (image: image.path) lilly.images);
    protected_datasets = lib.optionals (enabled "lilly") (map (pool: pool.storage.dataset) lilly.pools);
    excludes = cfg.excludePaths ++ [ "**/owner.lock" "**/.pending-*" "**/*.sock" ];
    lilly = if cfg.defaults.enable && enabled "lilly" then { tool = toString lillyTool; } else null;
    postgres = if cfg.postgres.enable then {
      ca_file = marshall.databaseCAFile;
      pg_dump = "${cfg.postgres.package}/bin/pg_dump";
      pg_restore = "${cfg.postgres.package}/bin/pg_restore";
      psql = "${cfg.postgres.package}/bin/psql";
      timeout = cfg.commandTimeoutSeconds;
    } else null;
  });
  command = operation: "${pkgs.python3}/bin/python3 ${scripts}/runtime.py ${descriptor} ${operation}";
  operator = pkgs.writeShellScriptBin "overalls-backup" ''
    set -eu
    properties=(--property=PrivateMounts=yes --property=UMask=0077)
    if [ "''${1:-}" != cleanup ]; then
      properties+=(--property=${lib.escapeShellArg "EnvironmentFile=${cfg.environmentFile}"})
      ${lib.optionalString cfg.postgres.enable ''properties+=(--property=${lib.escapeShellArg "EnvironmentFile=-${marshall.environmentFile}"})''}
    fi
    exec ${pkgs.systemd}/bin/systemd-run --quiet --wait --pipe --collect \
      "''${properties[@]}" ${pkgs.python3}/bin/python3 ${scripts}/runtime.py ${descriptor} "$@"
  '';
  preparation = cfg.secretUnits ++ lib.optionals cfg.postgres.enable
    (lib.filter (unit: lib.hasPrefix "overalls-secrets-" unit) marshall.secretUnits);
  service = operation: {
    description = "Overalls host backup ${operation}";
    wants = lib.optionals (operation != "cleanup") ([ "network-online.target" ] ++ preparation);
    after = [ "zfs-mount.service" ] ++ lib.optionals (operation != "cleanup") ([ "network-online.target" ] ++ preparation);
    # A failed secret preparer must still let the coordinator publish failure.
    # Runtime credential validation refuses repository access without them.
    requires = [];
    path = [ pkgs.coreutils pkgs.util-linux pkgs.zfs ];
    serviceConfig = {
      Type = "oneshot";
      User = "root";
      UMask = "0077";
      StateDirectory = "overalls-backups";
      StateDirectoryMode = "0700";
      CacheDirectory = "overalls-backups";
      CacheDirectoryMode = "0700";
      RuntimeDirectory = "overalls-backups";
      RuntimeDirectoryMode = "0700";
      RuntimeDirectoryPreserve = "yes";
      EnvironmentFile = lib.optionals (operation != "cleanup") ([ "-${cfg.environmentFile}" ]
        ++ lib.optional cfg.postgres.enable "-${marshall.environmentFile}");
      Environment = "PYTHONDONTWRITEBYTECODE=1";
      ExecStart = command operation;
      # Native ZFS verification must see writable host mounts. Keep mounts
      # private without ProtectSystem/PrivateDevices changing storage semantics.
      PrivateMounts = true;
      Nice = 10;
      CPUWeight = 10;
      IOWeight = 10;
      TimeoutStartSec = "infinity";
      TimeoutStopSec = 180;
      KillMode = "control-group";
    };
  };
in {
  options.services.overallsBackups = {
    enable = mkEnableOption "host recovery backups with Restic";
    package = mkOption { type = types.package; default = pkgs.restic; };
    s3 = {
      endpoint = mkOption { type = types.strMatching "https://[a-zA-Z0-9][a-zA-Z0-9.:-]*"; description = "S3 HTTPS endpoint without credentials or trailing slash."; };
      bucket = mkOption { type = types.strMatching "[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]"; };
      region = mkOption { type = types.strMatching "[a-zA-Z0-9-]+"; };
      prefix = mkOption { type = types.strMatching "[a-zA-Z0-9_-]+(/[a-zA-Z0-9_-]+)*"; default = "hosts"; };
    };
    passwordFile = mkOption { type = paths.privatePath; default = "/run/overalls-secrets/backup/password"; };
    environmentFile = mkOption { type = paths.privatePath; default = "/run/overalls-secrets/backup/s3.env"; };
    secretUnits = mkOption { type = types.listOf (types.strMatching "[a-zA-Z0-9_.@-]+\\.service"); default = [ "overalls-secrets-backup.service" ]; };
    schedule = mkOption { type = types.str; default = "*-*-* *:00,30:00"; };
    randomizedDelaySec = mkOption { type = types.ints.unsigned; default = 300; description = "Stable per-host random delay in seconds; spreads database and S3 load."; };
    retention.keepLast = mkOption { type = types.ints.positive; default = 12; };
    initialize = mkOption { type = types.bool; default = true; description = "Initialize only when Restic positively reports that the repository does not exist."; };
    defaults.enable = mkOption { type = types.bool; default = true; };
    extraPaths = mkOption { type = types.listOf paths.absolutePath; default = []; };
    excludePaths = mkOption { type = types.listOf types.str; default = []; };
    uploadLimitKiB = mkOption { type = types.ints.unsigned; default = 0; description = "Upload bandwidth cap in KiB/s; zero means unlimited."; };
    minimumFreeBytes = mkOption { type = types.ints.positive; default = 1073741824; description = "Minimum free Lilly pool space before capture and during upload."; };
    commandTimeoutSeconds = mkOption { type = types.ints.positive; default = 7200; };
    postgres = {
      enable = mkOption { type = types.bool; default = cfg.defaults.enable && enabled "marshall"; };
      package = mkOption { type = types.package; default = pkgs.postgresql_18; description = "pg_dump/pg_restore tools compatible with Marshall's database server."; };
    };
  };
  config = mkIf cfg.enable {
    assertions = [
      { assertion = !cfg.postgres.enable || enabled "marshall"; message = "Database backups require Marshall's configured runtime DATABASE_URL and TLS CA."; }
      { assertion = !(enabled "marshall") || marshall.ingress.wildcardAcme == null || cfg.postgres.enable;
        message = "Fleet wildcard certificate custody requires PostgreSQL backups on a Marshall host."; }
      { assertion = builtins.match "[a-z][a-z0-9-]{0,62}" config.networking.hostName != null; message = "Backup repositories require a stable safe hostname."; }
    ];
    environment.systemPackages = [ operator cfg.package ];
    systemd.services = {
      overalls-backup = service "backup";
      overalls-backup-prune = service "prune";
      overalls-backup-check = service "check";
      overalls-backup-read-check = service "read-check";
      overalls-backup-cleanup = (service "cleanup") // { wantedBy = [ "multi-user.target" ]; };
    };
    systemd.timers = import ./timers.nix { inherit cfg; };
  };
}
