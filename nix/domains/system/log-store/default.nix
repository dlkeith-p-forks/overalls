{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption mkIf types;
  cfg = config.services.overallsLogStore;
  paths = import ../types.nix { inherit lib; };
  entry = "logstore-entry";
  runtime = "/run/${entry}";
  backend = "127.0.0.1:${toString cfg.backendPort}";
in {
  options.services.overallsLogStore = {
    enable = mkEnableOption "fleet diagnostic log store (VictoriaLogs) with a path-scoped fleet entry";
    address = mkOption {
      type = types.nullOr paths.ipv4;
      default = null;
      description = "WireGuard fleet IPv4 the entry binds; never a public or wildcard address.";
    };
    port = mkOption { type = types.port; default = 8443; };
    backendPort = mkOption { type = types.port; default = 9428; description = "Loopback-only VictoriaLogs HTTP port."; };
    certificateFile = mkOption {
      type = paths.privatePath;
      description = "Runtime leaf certificate for the fleet entry (full chain).";
    };
    keyFile = mkOption { type = paths.privatePath; description = "Runtime leaf private key for the fleet entry."; };
    insertPasswordFile = mkOption {
      type = paths.privatePath;
      description = "Runtime insert credential; admits only /insert/* paths.";
    };
    readerPasswordFile = mkOption {
      type = paths.privatePath;
      description = "Runtime reader credential; admits only /select/* and health paths.";
    };
    retentionDays = mkOption { type = types.ints.positive; default = 30; };
    minFreeBytes = mkOption {
      type = types.ints.positive;
      default = 5368709120;
      description = "Store refuses ingestion when free disk falls below this many bytes.";
    };
    stateDataset = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Optional ZFS dataset mounted at the store state directory with a hard refquota. Uses a static service user (DynamicUser bind-mounts conflict with pre-mounted datasets).";
    };
    stateQuotaGiB = mkOption { type = types.ints.positive; default = 20; };
    storeMemoryMiB = mkOption { type = types.ints.positive; default = 1024; };
    storeCpuPercent = mkOption { type = types.ints.positive; default = 200; };
    entryMemoryMiB = mkOption { type = types.ints.positive; default = 64; };
    secretUnits = mkOption { type = types.listOf types.str; default = []; };
  };
  config = mkIf cfg.enable {
    assertions = [
      { assertion = cfg.address != null && !(lib.hasPrefix "0." cfg.address);
        message = "The log store entry requires an explicit non-wildcard IPv4 address."; }
      { assertion = cfg.port != cfg.backendPort;
        message = "The log store entry and backend ports must differ."; }
      { assertion = cfg.insertPasswordFile != cfg.readerPasswordFile;
        message = "Insert and reader credentials must be distinct files."; }
      { assertion = cfg.stateDataset == null || !lib.hasPrefix "/" cfg.stateDataset;
        message = "The log store dataset is a ZFS dataset name, not a path."; }
    ];

    services.victorialogs = {
      enable = true;
      listenAddress = backend;
      extraOptions = [
        "-retentionPeriod=${toString cfg.retentionDays}d"
        "-storage.minFreeDiskSpaceBytes=${toString cfg.minFreeBytes}"
        "-loggerLevel=WARN"
      ];
    };
    users.groups.victorialogs = mkIf (cfg.stateDataset != null) {};
    users.users.victorialogs = mkIf (cfg.stateDataset != null) {
      isSystemUser = true;
      group = "victorialogs";
    };
    # @cc [owner:ghuntley,label:security;capacity] logstore-loopback-bounded-backend
    # VictoriaLogs MUST bind loopback only, without its own authentication, and
    # run under explicit memory/CPU allowances with time and disk guards. Fleet
    # authority lives exclusively in the entry frontend.
    systemd.services.victorialogs = {
      after = lib.optional (cfg.stateDataset != null) "logstore-data.service";
      requires = lib.optional (cfg.stateDataset != null) "logstore-data.service";
      serviceConfig = {
        MemoryMax = "${toString cfg.storeMemoryMiB}M";
        CPUQuota = "${toString cfg.storeCpuPercent}%";
      } // lib.optionalAttrs (cfg.stateDataset != null) {
        # systemd's DynamicUser state-directory bind mount conflicts with a
        # pre-mounted ZFS dataset (EBUSY); a fixed user owns it instead.
        DynamicUser = lib.mkForce false;
        User = "victorialogs";
        Group = "victorialogs";
      };
    };
    systemd.services.logstore-data = mkIf (cfg.stateDataset != null) {
      description = "Prepare quota-bound log store dataset";
      wantedBy = [ "victorialogs.service" ];
      before = [ "victorialogs.service" ];
      after = [ "zfs-mount.service" ];
      requires = [ "zfs-mount.service" ];
      path = [ config.boot.zfs.package pkgs.coreutils ];
      script = ''
        if ! zfs list -H ${lib.escapeShellArg cfg.stateDataset} >/dev/null 2>&1; then
          zfs create -o mountpoint=/var/lib/victorialogs \
            -o refquota=${toString cfg.stateQuotaGiB}G ${lib.escapeShellArg cfg.stateDataset}
        fi
        test "$(zfs get -H -o value mountpoint ${lib.escapeShellArg cfg.stateDataset})" = /var/lib/victorialogs
        zfs set refquota=${toString cfg.stateQuotaGiB}G ${lib.escapeShellArg cfg.stateDataset}
        zfs mount ${lib.escapeShellArg cfg.stateDataset} || true
        test "$(zfs get -H -o value mounted ${lib.escapeShellArg cfg.stateDataset})" = yes
        chown victorialogs:victorialogs /var/lib/victorialogs
        chmod 0700 /var/lib/victorialogs
      '';
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
    };

    # @cc [owner:ghuntley,label:security] logstore-runtime-credentials
    # Entry configuration MUST render at service start from systemd-loaded
    # credentials into root-only runtime files. The Nix store copy stays a
    # placeholder template; substitutions refuse empty values.
    systemd.services.${entry} = {
      description = "Path-scoped authenticated fleet entry for the diagnostic log store";
      wantedBy = [ "multi-user.target" ];
      after = [ "network-online.target" "victorialogs.service" ] ++ cfg.secretUnits;
      wants = [ "network-online.target" ];
      requires = [ "victorialogs.service" ] ++ cfg.secretUnits;
      serviceConfig = {
        Type = "exec";
        DynamicUser = true;
        UMask = "0077";
        LoadCredential = [
          "tls.crt:${cfg.certificateFile}"
          "tls.key:${cfg.keyFile}"
          "insert.password:${cfg.insertPasswordFile}"
          "reader.password:${cfg.readerPasswordFile}"
        ];
        RuntimeDirectory = entry;
        RuntimeDirectoryMode = "0700";
        Restart = "on-failure";
        RestartSec = 5;
        MemoryMax = "${toString cfg.entryMemoryMiB}M";
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
      preStart = ''
        install -m 0400 "$CREDENTIALS_DIRECTORY/tls.crt" ${runtime}/tls.crt
        cat "$CREDENTIALS_DIRECTORY/tls.crt" "$CREDENTIALS_DIRECTORY/tls.key" > ${runtime}/tls.pem
        chmod 0400 ${runtime}/tls.pem
        insert_password="$(cat "$CREDENTIALS_DIRECTORY/insert.password")"
        reader_password="$(cat "$CREDENTIALS_DIRECTORY/reader.password")"
        test -n "$insert_password" && test -n "$reader_password"
        ${pkgs.gawk}/bin/awk \
          -v insert="$insert_password" -v reader="$reader_password" \
          -v address=${lib.escapeShellArg cfg.address} -v port=${toString cfg.port} \
          -v backend=${toString cfg.backendPort} -v pem=${runtime}/tls.pem \
          '{ gsub(/__INSERT_PASSWORD__/, insert); gsub(/__READER_PASSWORD__/, reader); \
             gsub(/__ADDRESS__/, address); gsub(/__PORT__/, port); \
             gsub(/__BACKEND_PORT__/, backend); gsub(/__TLS_PEM__/, pem); print }' \
          ${./haproxy.conf.template} > ${runtime}/haproxy.cfg
        chmod 0400 ${runtime}/haproxy.cfg
        ! ${pkgs.gnugrep}/bin/grep -q "__.*__" ${runtime}/haproxy.cfg
      '';
      script = ''
        exec ${pkgs.haproxy}/sbin/haproxy -Ws -db -f ${runtime}/haproxy.cfg
      '';
    };
  };
}
