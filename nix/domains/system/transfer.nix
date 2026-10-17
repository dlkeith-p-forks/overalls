{ packages }:
{ config, lib, pkgs, ... }:
let
  cfg = config.services.lillyTransfer;
  # ADR-0182: the transfer state belongs to `lilly` and the root workers
  # trust files that uid wrote. A host without the Lilly service (a bare
  # export source) has no `lilly` user, so only root-written state is trusted.
  hasService = config.users.users ? lilly;
  serviceUid = lib.optionalString hasService
    "export LILLY_SERVICE_UID=${toString config.users.users.lilly.uid}";
  localTypes = import ./types.nix { inherit lib; };
  socket = "/run/lilly-transfer/export.sock";
  channel = "${packages.hostTools}/bin/lilly-export-channel";
  bridge = pkgs.writeShellScript "lilly-transfer-bridge" ''
    exec ${channel} bridge ${socket} "$@"
  '';
  worker = pkgs.writeShellScript "lilly-transfer-worker" ''
    export PATH="${config.boot.zfs.package}/bin:${cfg.package}/host-tools/bin:/run/current-system/sw/bin"
    export ERL_FLAGS="+S 2:2"
    export RELEASE_DISTRIBUTION=none
    export RELEASE_COOKIE=isolated-export-worker
    export RELEASE_TMP=/run/lilly-transfer/release
    ${serviceUid}
    exec ${cfg.package}/bin/lilly eval 'Lilly.Transfer.Endpoint.export_main("${cfg.configurationFile}")'
  '';
  authorize = pkgs.writeShellScript "lilly-transfer-authorize" ''
    export PATH="${config.boot.zfs.package}/bin:${cfg.package}/host-tools/bin:/run/current-system/sw/bin"
    export ERL_FLAGS="+S 2:2"
    export RELEASE_DISTRIBUTION=none
    export RELEASE_COOKIE=isolated-export-authorize
    export RELEASE_TMP=/run/lilly-transfer/release
    ${serviceUid}
    export LILLY_SSH_USER="$1" LILLY_SSH_TYPE="$2" LILLY_SSH_KEY="$3"
    exec ${cfg.package}/bin/lilly eval 'Lilly.Transfer.Endpoint.authorize_main("${cfg.configurationFile}", "${bridge}")'
  '';
  sshConfig = pkgs.writeText "lilly-transfer-sshd.conf" ''
    AddressFamily inet
    Port ${toString cfg.port}
    ListenAddress ${cfg.listenAddress}
    HostKey ${cfg.hostKeyFile}
    PidFile /run/lilly-transfer/sshd.pid
    AllowUsers lilly-transfer
    PermitRootLogin no
    AuthenticationMethods publickey
    PubkeyAcceptedAlgorithms ssh-ed25519
    PasswordAuthentication no
    KbdInteractiveAuthentication no
    UsePAM no
    AuthorizedKeysFile none
    AuthorizedKeysCommand /etc/lilly-transfer-authorize %u %t %k
    AuthorizedKeysCommandUser root
    StrictModes yes
    PermitUserEnvironment no
    PermitUserRC no
    DisableForwarding yes
    PermitTTY no
    PermitTunnel no
    X11Forwarding no
    MaxAuthTries 2
    MaxSessions 1
    MaxStartups 4:30:8
    LoginGraceTime 30
    LogLevel ERROR
  '';
in {
  options.services.lillyTransfer = {
    enable = lib.mkEnableOption "restricted permit-bound Lilly ZFS export";
    package = lib.mkOption {
      type = lib.types.package;
      default = packages.lilly;
      description = "Source-built Lilly release used by isolated export workers.";
    };
    configurationFile = lib.mkOption {
      type = localTypes.privatePath;
      description = "Private v3 export configuration containing local host, journal root and bound pools; no control-plane credentials.";
    };
    stateDirectory = lib.mkOption {
      type = localTypes.privatePath;
      default = "/var/lib/lilly/transfers";
      description = "Durable transfer journal root used by Lilly's generated export configuration.";
    };
    hostKeyFile = lib.mkOption {
      type = localTypes.privatePath;
      default = "/etc/ssh/ssh_host_ed25519_key";
      description = "Existing enrolled source host identity. This service never generates or replaces it.";
    };
    listenAddress = lib.mkOption {
      type = localTypes.ipv4;
      default = "0.0.0.0";
      description = "Local IPv4 address for the dedicated SSH listener.";
    };
    port = lib.mkOption { type = lib.types.port; default = 2222; };
    openFirewall = lib.mkOption { type = lib.types.bool; default = false; };
  };

  # @cc [owner:ghuntley,label:security;recovery] installed-transfer-channel-boundary
  # The listener MUST allow only permit-derived forced commands for the dedicated
  # account. Root export workers MUST be reachable only through the account's
  # restricted socket and verify peer credentials, selected key and current permit.
  # Helpers MUST NOT gain setuid/capabilities. Guest units MUST remain independent
  # of these services. Existing host keys and durable journals MUST survive updates.
  config = lib.mkIf cfg.enable {
    assertions = [
      { assertion = !config.services.openssh.enable || !(builtins.elem cfg.port config.services.openssh.ports);
        message = "Lilly transfer and administrative SSH require distinct ports."; }
    ];
    boot.supportedFilesystems = [ "zfs" ];
    # OpenSSH needs this account even when the ordinary listener is disabled.
    users.groups.sshd = {};
    users.users.sshd = { isSystemUser = true; group = "sshd"; };
    users.groups.lilly-transfer = {};
    users.users.lilly-transfer = {
      isSystemUser = true;
      group = "lilly-transfer";
      home = "/var/empty";
      createHome = false;
      shell = pkgs.bash;
      hashedPassword = "*";
    };
    # This account's only SSH entry is the dedicated forced-command listener.
    services.openssh.settings.DenyUsers = [ "lilly-transfer" ];
    networking.firewall.allowedTCPPorts = lib.mkIf cfg.openFirewall [ cfg.port ];
    environment.etc."lilly-transfer-authorize" = {
      source = authorize;
      mode = "0555";
    };
    systemd.tmpfiles.rules = [
      "d /run/lilly-transfer 0750 root lilly-transfer -"
      "d /run/lilly-transfer/release 0700 root root -"
      "d ${cfg.stateDirectory} 0700 ${if hasService then "lilly lilly" else "root root"} -"
    ];
    systemd.slices.lillyexport = {
      description = "Bounded export workers outside the guest reservation slice";
      sliceConfig = {
        CPUAccounting = true;
        MemoryAccounting = true;
        TasksAccounting = true;
        CPUQuota = "200%";
        MemoryMax = "1G";
        TasksMax = 512;
      };
    };
    systemd.sockets.lilly-transfer-export = {
      wantedBy = [ "sockets.target" ];
      after = [ "systemd-tmpfiles-setup.service" ];
      socketConfig = {
        ListenStream = socket;
        Accept = true;
        SocketUser = "root";
        SocketGroup = "lilly-transfer";
        SocketMode = "0660";
        DirectoryMode = "0750";
        MaxConnections = 4;
      };
    };
    systemd.services."lilly-transfer-export@" = {
      serviceConfig = {
        Slice = "lillyexport.slice";
        ExecStart = "${channel} serve lilly-transfer ${worker}";
        StandardInput = "socket";
        StandardOutput = "journal";
        StandardError = "journal";
        User = "root";
        Group = "root";
        UMask = "0077";
        KillMode = "control-group";
        TimeoutStopSec = 310;
        NoNewPrivileges = true;
        # No RestrictSUIDSGID: its seccomp filter fails every openat2 with
        # ENOSYS, and the worker's private lilly-hostd opens every lock with
        # openat2, so each pool lease would be refused (storage_busy).
        RestrictAddressFamilies = [ "AF_UNIX" ];
        MemoryMax = "512M";
        TasksMax = 128;
        LimitNOFILE = 256;
      };
    };
    systemd.services.lilly-transfer-sshd = {
      description = "Restricted Lilly source export SSH listener";
      wantedBy = [ "multi-user.target" ];
      after = [ "network.target" "sshd.service" "systemd-tmpfiles-setup.service" "lilly-transfer-export.socket" ];
      requires = [ "lilly-transfer-export.socket" ];
      preStart = ''
        test -s ${lib.escapeShellArg cfg.configurationFile}
        test -s ${lib.escapeShellArg cfg.hostKeyFile}
        export PATH="${config.boot.zfs.package}/bin:${cfg.package}/host-tools/bin:/run/current-system/sw/bin"
        export ERL_FLAGS="+S 2:2"
        export RELEASE_DISTRIBUTION=none
        export RELEASE_COOKIE=isolated-export-validation
        export RELEASE_TMP=/run/lilly-transfer/release
        ${serviceUid}
        ${cfg.package}/bin/lilly eval 'Lilly.Transfer.Endpoint.check_main("${cfg.configurationFile}")'
        ${pkgs.openssh}/bin/sshd -t -f ${sshConfig}
      '';
      serviceConfig = {
        Slice = "lillyexport.slice";
        ExecStart = "${pkgs.openssh}/bin/sshd -D -e -f ${sshConfig}";
        Restart = "on-failure";
        RestartSec = 5;
        User = "root";
        Group = "root";
        UMask = "0077";
        KillMode = "control-group";
        NoNewPrivileges = true;
        LimitNOFILE = 256;
        TasksMax = 256;
      };
    };
  };
}
