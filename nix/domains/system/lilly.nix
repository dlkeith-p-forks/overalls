{ packages }:
{ config, lib, pkgs, ... }:
let
  inherit (lib) mkOption mkEnableOption mkIf types;
  cfg = config.services.lilly;
  audiConnector = cfg.ingress.enable || cfg.privateServices.enable;
  dumps = import ./crash-dumps { inherit lib pkgs; };
  hasZfs = cfg.pools != [];
  hasBrady = config.services.brady.enable or false;
  localTypes = import ./types.nix { inherit lib; };
  # lilly-hostd resolves its closed utility table from exactly Lilly's PATH.
  utilityPath = lib.optionals hasZfs [ config.boot.zfs.package ] ++ [ "${cfg.package}/host-tools" pkgs.systemd ];
  # @cc [owner:ghuntley,label:security] lilly-units-namespace-free-hardening
  # Both units MUST stay in the host mount namespace: hostd mounts guest
  # datasets for the host, and the pool is recursively private, so a Lilly
  # mount namespace would never see new guest dataset mounts (ADR-0144). Their
  # hardening is therefore namespace-free: capabilities neither process uses
  # are removed from the bounding set, and foreign-architecture syscalls,
  # personality changes and realtime scheduling are refused.
  # MemoryDenyWriteExecute stays off because the BEAM JIT needs it, and
  # RestrictSUIDSGID MUST stay off because its seccomp filter fails every
  # openat2 with ENOSYS, and hostd opens every lock and socket with openat2.
  hardening = {
    CapabilityBoundingSet = "~CAP_SYS_MODULE CAP_SYS_BOOT CAP_SYS_TIME CAP_WAKE_ALARM CAP_SYSLOG CAP_AUDIT_CONTROL CAP_AUDIT_READ CAP_AUDIT_WRITE CAP_MAC_ADMIN CAP_MAC_OVERRIDE CAP_SYS_PACCT CAP_SYS_TTY_CONFIG CAP_LEASE CAP_BLOCK_SUSPEND CAP_LINUX_IMMUTABLE";
    SystemCallArchitectures = "native";
    LockPersonality = true;
    RestrictRealtime = true;
  };
  # The BEAM always runs as `lilly` (ADR-0182); hostd is the only root component.
  serviceUser = "lilly";
  serviceUid = toString config.users.users.lilly.uid;
  # Root-owned secrets reach the BEAM only as systemd credentials.
  secretPath = name: "/run/credentials/lilly.service/${name}";
  # The control-plane CA is public, but its path may be root-only (a fixture's
  # private state directory); systemd reads it as root and hands the service
  # user a private copy, exactly as it does the credential.
  loadCredentials = [ "credential:${cfg.credentialFile}" "control-ca:${cfg.controlPlaneCAFile}" ]
    ++ lib.optional (cfg.inceptionSMTPFile != null) "inception-smtp:${cfg.inceptionSMTPFile}";
  # Directories the BEAM owns (its private state and runtime).
  ownedDirectories = lib.unique ([ "/run/lilly" "/var/lib/lilly" "/run/lilly-clone-copies" cfg.stateDirectory cfg.vmStateDirectory cfg.networkStateDirectory ]
    ++ map (pool: pool.path) cfg.pools);
  transferStateDirectory = if config.services.lillyTransfer.enable
    then config.services.lillyTransfer.stateDirectory else null;
  hostdSocket = "/run/lilly-hostd/control.sock";
  hostdRoots = lib.unique ([ "/run" "/var/lib/lilly" cfg.stateDirectory cfg.vmStateDirectory cfg.networkStateDirectory ]
    ++ map (pool: pool.path) cfg.pools
    ++ lib.optional (config.services.lillyTransfer.enable or false) config.services.lillyTransfer.stateDirectory);
  # Native file effects (chmod, chown, mv, rm, truncate, mkfifo, sync) act only
  # beneath these: Lilly's own state and pools, never all of /run
  # (native-file-effects-beneath-roots).
  # The /run entries are the directories Lilly locks and publishes in: its
  # own state, clone and backup mounts, and the sockets it serves.
  fileRoots = lib.unique ([ "/run/lilly" "/run/lilly-clone-copies" "/run/overalls-backups"
      "/run/lilly-ingress" "/run/lilly-brady" "/run/lilly-inception" "/run/audi-private" "/run/ziggy"
      "/var/lib/overalls-firecracker" ]
    ++ lib.remove "/run" hostdRoots);
  uplink = "lu${builtins.substring 0 12 (builtins.hashString "sha256" cfg.hostId)}";
  guestTrustRootFiles = map (path: pkgs.runCommand "lilly-public-guest-root.pem" {} ''
    cp ${path} "$out"
  '') cfg.guestTrustRoots;
  configuration = pkgs.writeText "lilly-public-config.json" (builtins.toJSON {
    version = 4;
    control_plane = cfg.controlPlane;
    host_id = cfg.hostId;
    credential_file = secretPath "credential";
    cacertfile = secretPath "control-ca";
    state_dir = cfg.stateDirectory;
    transfer_state_dir = transferStateDirectory;
    transfer_bytes_per_second = cfg.transferBytesPerSecond;
    local_transfer_bytes_per_second = cfg.localTransferBytesPerSecond;
    cgroup_path = "/sys/fs/cgroup/lilly.slice";
    images = map (image: { inherit (image) path; }) cfg.images;
    pools = map (pool: pool // {
      template_budget_bytes = cfg.imageTemplates.budgetBytes;
      image_io_timeout_ms = cfg.imageIoTimeoutSeconds * 1000;
    }) cfg.pools;
    ingress = if audiConnector then {
      path = "/run/lilly-ingress/audi.sock";
      audi_uid = 0; # Replaced with the deployed Audi UID before publication.
    } else null;
    execution = {
      audi_ingress = cfg.ingress.enable;
      private_services = cfg.privateServices.enable;
      guest_trust_roots = map toString guestTrustRootFiles;
      brady = if hasBrady then {
        uid = 0; # Replaced with the deployed dedicated UID before publication.
        http_ports = config.services.brady.httpPorts;
        https_ports = config.services.brady.httpsPorts;
        dns = config.services.brady.dnsResolvers;
      } else null;
      firecracker_logging = cfg.firecrackerLogging.enable;
      inception_smtp_file = if cfg.inceptionSMTPFile == null then null else secretPath "inception-smtp";
      inception_image_id = cfg.inceptionImageId;
      inception_proof_file = if cfg.inceptionImageId == null then null else "/run/lilly-inception/proof.json";
      inception_probe_id = if cfg.inceptionImageId == null then null else toString packages.inceptionProbeGuest;
      state_dir = cfg.vmStateDirectory;
      network_state_dir = cfg.networkStateDirectory;
      egress_interface = cfg.egressInterface;
      protected_cidrs = cfg.protectedCidrs;
    };
  });
in
{
  imports = [ ./crash-dumps/retention.nix ./firecracker-logging (import ./transfer.nix { inherit packages; }) ];
  options.services.lilly = {
    transferBytesPerSecond = mkOption {
      type = types.ints.between 1 1073741824;
      default = 67108864;
      description = "Maximum receive stream bytes per second, with a 64 KiB burst allowance.";
    };
    localTransferBytesPerSecond = mkOption {
      type = types.ints.between 1 1073741824;
      default = 1073741824;
      description = "Maximum same-host clone stream bytes per second; these never cross the network.";
    };
    enable = mkEnableOption "Lilly Firecracker provisioner";
    imageTemplates.budgetBytes = mkOption {
      type = types.ints.between 1 1099511627776;
      default = 34359738368;
      description = "Conservative per-pool artifact budget for sealed image templates (ADR-0130); images larger than the budget use fresh verification for every provision.";
    };
    imageIoTimeoutSeconds = mkOption {
      type = types.ints.between 1 14400;
      default = 300;
      description = "Deadline for one root-disk image copy or flush per pool (ADR-0173); expiry fails the placement closed. Raise it only where image I/O is known to be slow, such as nested test hosts reading a non-sparse store.";
    };
    crashDumps = dumps.options;
    privateServices.enable = mkEnableOption "registered private DNS and HTTPS in the owned namespace";
    guestTrustRoots = mkOption {
      type = types.listOf types.path;
      default = [];
      description = "Public platform CA certificates delivered to each guest on boot.";
    };
    ingress.enable = mkEnableOption "restricted local Audi guest SSH ingress";
    inceptionSMTPFile = mkOption {
      type = types.nullOr localTypes.privatePath;
      default = null;
      description = "Private runtime JSON containing only shared Inception SMTP configuration; null disables Inception bootstrap.";
    };
    inceptionImageId = mkOption {
      type = types.nullOr (types.strMatching "sha256:[0-9a-f]{64}");
      default = null;
      description = "Exact locally installed Inception image allowed to receive the shared SMTP bundle.";
    };
    package = mkOption {
      type = types.package;
      default = if cfg.crashDumps.enable then packages.encrypted.lilly else packages.lilly;
      description = "Source-built Lilly release with canonical host-tool metadata.";
    };
    hostId = mkOption {
      type = localTypes.uuid;
      description = "Enrolled, persistent Marshall host resource UUID.";
    };
    controlPlane = mkOption {
      type = types.strMatching "https://([a-zA-Z0-9][a-zA-Z0-9.-]*|[[][0-9a-fA-F:]+[]])(:[0-9]{1,5})?/?";
      description = "Verified HTTPS control-plane origin; no embedded credentials.";
    };
    controlPlaneCAFile = mkOption {
      type = localTypes.absolutePath;
      default = "${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt";
      description = "CA bundle authenticating the control-plane endpoint. Lilly reads it through systemd LoadCredential, so the file may be readable by root only.";
    };
    credentialFile = mkOption {
      type = localTypes.privatePath;
      default = "/run/overalls-secrets/lilly-credential.json";
      description = "Private host-bound enrollment credential file.";
    };
    secretUnits = mkOption {
      type = types.listOf (types.strMatching "[a-zA-Z0-9_.@-]+\\.service");
      default = [];
      description = "Required preparation services that publish runtime credentials.";
    };
    hostd.peerCgroups = mkOption {
      type = types.listOf types.str;
      default = [ "/system.slice/lilly.service" ];
      description = ''
        cgroup v2 paths whose root processes may open a lilly-hostd session.
        Lilly's own unit by default; an empty list admits any root peer
        (machine tests whose probe BEAMs run outside lilly.service).
      '';
    };
    stateDirectory = mkOption {
      type = localTypes.privatePath;
      default = "/var/lib/lilly/control";
      description = "Durable control receipt and host ownership directory.";
    };
    vmStateDirectory = mkOption {
      type = localTypes.privatePath;
      default = "/var/lib/lilly/vms";
      description = "Durable VM actor directory; maximum 45 bytes for UNIX sockets.";
    };
    networkStateDirectory = mkOption {
      type = localTypes.privatePath;
      default = "/var/lib/lilly/network";
      description = "Durable host networking ownership directory.";
    };
    egressInterface = mkOption {
      type = types.strMatching "[a-zA-Z0-9][a-zA-Z0-9_.-]{0,14}";
      description = "Host uplink carrying routed guest egress.";
    };
    protectedCidrs = mkOption {
      type = types.listOf (types.strMatching "[0-9.]+/[0-9]+");
      default = [];
      description = "Additional canonical IPv4 networks denied to guests, including public management endpoints.";
    };
    guestCpuCores = mkOption {
      type = types.ints.positive;
      default = 24;
      description = "Aggregate guest CPU quota in logical cores.";
    };
    guestMemoryMiB = mkOption {
      type = types.ints.positive;
      default = 98304;
      description = "Aggregate guest and VMM memory budget in MiB.";
    };
    images = mkOption {
      type = types.listOf (types.submodule {
        options = {
          path = mkOption {
            type = localTypes.absolutePath;
            description = "Immutable local image directory (manifest.json and artifacts) verified by Lilly before advertising.";
          };
        };
      });
      default = [];
      description = "Immutable local images verified by Lilly before advertising, in operator order.";
    };
    pools = mkOption {
      default = [];
      description = "Bound storage pools; filesystem identity must match the actual mount.";
      type = types.listOf (types.submodule {
        options = {
          id = mkOption { type = localTypes.uuid; description = "Enrolled pool UUID."; };
          path = mkOption { type = localTypes.privatePath; description = "Canonical mounted pool path."; };
          filesystem_id = mkOption { type = types.str; description = "Verified filesystem identity."; };
          storage = mkOption {
            description = "Required native ZFS pool and dataset identity.";
            type = types.submodule {
              options = {
                backend = mkOption { type = types.enum [ "zfs" ]; default = "zfs"; };
                zpool_guid = mkOption { type = types.strMatching "[1-9][0-9]{0,19}"; description = "Actual unsigned 64-bit zpool GUID as a decimal string."; };
                dataset_guid = mkOption { type = types.strMatching "[1-9][0-9]{0,19}"; description = "Actual parent dataset GUID as a decimal string."; };
                dataset = mkOption { type = types.strMatching "[a-zA-Z][a-zA-Z0-9_.-]*(/[a-zA-Z0-9][a-zA-Z0-9_.-]*)+"; description = "Existing mounted parent dataset, with LZ4 and no reservations."; };
              };
            };
          };
          max_iops = mkOption {
            type = types.nullOr types.ints.positive;
            default = null;
            description = "Measured or configured IOPS limit; null means unknown. ZFS uses logical whole-pool operations. This is monitoring metadata, not admission capacity.";
          };
          max_iops_source = mkOption {
            type = types.nullOr types.str;
            default = null;
            description = "Provenance of the IOPS limit.";
          };
        };
      });
    };
  };

  config = mkIf cfg.enable {
    # @cc [owner:ghuntley,label:deployment] lilly-required-transfer
    # Every enabled Lilly MUST install its restricted transfer service. Explicit
    # disablement MUST fail evaluation; administrative SSH keeps its own port.
    services.lillyTransfer.enable = lib.mkDefault true;
    services.lillyTransfer.port = lib.mkDefault 2223;
    services.lillyTransfer.openFirewall = lib.mkDefault true;
    services.lillyTransfer.configurationFile = lib.mkDefault "/etc/lilly-transfer.json";
    environment.etc."lilly-transfer.json" = lib.mkIf config.services.lillyTransfer.enable {
      mode = "0600";
      source = pkgs.writeText "lilly-transfer-config.json" (builtins.toJSON {
        version = 3;
        host_id = cfg.hostId;
        root = config.services.lillyTransfer.stateDirectory;
        pools = map (pool: {
          inherit (pool) id path filesystem_id storage;
        }) cfg.pools;
      });
    };
    services.overallsCrashDumpRetention.directories = lib.mkIf cfg.crashDumps.enable ([ "/var/lib/lilly-crash-dumps" ]);
    systemd.coredump.settings.Coredump = lib.mkIf cfg.crashDumps.enable { Storage = "none"; ProcessSizeMax = 0; };
    assertions = [
      { assertion = config.services.lillyTransfer.enable;
        message = "Enabled Lilly requires its restricted transfer service."; }
      { assertion = (cfg.inceptionImageId == null) == (cfg.inceptionSMTPFile == null);
        message = "Inception requires both an installed image ID and a private SMTP file."; }
      { assertion = !cfg.ingress.enable ||
          ((lib.attrByPath [ "services" "audi" "enable" ] false config)
            && config.services.audi.hostId == cfg.hostId
            && config.services.audi.connectorPath == "/run/lilly-ingress/audi.sock"
            && config.services.audi.connectorUid == config.users.users.lilly.uid);
        message = "Lilly ingress requires the local Audi gateway with matching host and Lilly service-user connector identity."; }
      { assertion = !config.services.lillyTransfer.enable || hasZfs;
        message = "Lilly transfer export requires at least one configured native ZFS pool."; }
      { assertion = !cfg.privateServices.enable || cfg.guestTrustRoots != [];
        message = "Lilly private guest services require public boot trust roots."; }
      { assertion = lib.all (path:
          let lines = lib.splitString "\n" (builtins.readFile path);
          in lib.any (line: lib.hasInfix "BEGIN CERTIFICATE" line) lines
            && !(lib.any (line: lib.hasInfix "PRIVATE KEY" line) lines)
        ) cfg.guestTrustRoots;
        message = "Lilly guest trust roots must contain public certificates and no private key."; }
      { assertion = !cfg.crashDumps.enable || cfg.crashDumps.publicKeyFile != null; message = "Encrypted dumps require an operator public key file."; }
      { assertion = pkgs.stdenv.hostPlatform.system == "x86_64-linux";
        message = "Lilly's current jailed runtime requires x86_64 Linux."; }
      { assertion = builtins.stringLength cfg.vmStateDirectory <= 45;
        message = "Lilly VM state directory exceeds the UNIX socket path budget."; }
      { assertion = builtins.length (lib.unique [ cfg.stateDirectory cfg.vmStateDirectory cfg.networkStateDirectory ]) == 3;
        message = "Lilly control, VM and network state directories must be distinct."; }
      { assertion = builtins.length cfg.pools <= 64 && builtins.length cfg.images <= 128;
        message = "Lilly supports at most 64 pools and 128 image manifests per host."; }
      { assertion = lib.all (pool: (pool.max_iops == null) == (pool.max_iops_source == null)) cfg.pools;
        message = "Each Lilly IOPS limit must include its provenance."; }
      { assertion = lib.all (pool: (builtins.stringLength pool.storage.dataset <= 200 && pool.filesystem_id == "zfs:${pool.storage.zpool_guid}:${pool.storage.dataset_guid}")) cfg.pools;
        message = "ZFS filesystem identity must match both GUIDs and leave room for child dataset names."; }
      { assertion = let ids = map (pool: pool.storage.zpool_guid) cfg.pools;
        in builtins.length (lib.unique ids) == builtins.length ids;
        message = "Only one schedulable Lilly parent per zpool is supported."; }
      { assertion = !config.networking.nftables.flushRuleset;
        message = "Lilly requires nftables reloads to preserve its independently owned isolation tables."; }
    ];

    # @cc [owner:ghuntley,label:isolation;recovery] nix-builds-exclude-guest-datasets
    # Nix build sandboxes run in user namespaces, so guest dataset mounts copied
    # into them are locked: ordinary unmount refuses them and fenced deletion
    # stalls until the build exits (ADR-0144). nix-daemon MUST run in its own
    # (slave) mount namespace from which every Lilly pool mount is removed by the
    # daemon process itself before it serves builds, so later guest mounts have
    # no parent to propagate into and sandboxes never copy a guest dataset.
    # Host builds, including root's, MUST go through that daemon.
    environment.variables.NIX_REMOTE = lib.mkIf hasZfs "daemon";
    systemd.services.nix-daemon = lib.mkIf hasZfs {
      after = [ "zfs-mount.service" ];
      serviceConfig = {
        PrivateMounts = true;
        ExecStart = [
          ""
          "@${pkgs.writeShellScript "nix-daemon-without-lilly-pools" ''
            ${lib.concatMapStringsSep "\n" (pool:
              "${pkgs.util-linux}/bin/umount --recursive --lazy ${lib.escapeShellArg pool.path} 2>/dev/null || true")
              cfg.pools}
            exec ${config.nix.package}/bin/nix-daemon --daemon
          ''} nix-daemon"
        ];
      };
    };

    # @cc [owner:ghuntley,label:isolation;recovery] lilly-pool-mounts-private
    # Services with PrivateUsers=true (Prometheus, VictoriaLogs) and rootless
    # containers keep slave copies of host mounts inside user namespaces, where
    # propagated guest dataset mounts are locked and fenced deletion can never
    # confirm cleanup (ADR-0144). Every Lilly pool mount MUST be recursively
    # private in the host namespace before Lilly starts, so guest mounts never
    # propagate out and existing slaves are detached from the pool's peer group.
    systemd.services.lilly-pool-propagation = lib.mkIf hasZfs {
      description = "Keep Lilly pool mounts out of other mount namespaces";
      wantedBy = [ "multi-user.target" ];
      after = [ "zfs-mount.service" ];
      before = [ "lilly.service" ];
      unitConfig.RequiresMountsFor = map (pool: pool.path) cfg.pools;
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      script = lib.concatMapStringsSep "\n" (pool: ''
        if ${pkgs.util-linux}/bin/mountpoint -q ${lib.escapeShellArg pool.path}; then
          ${pkgs.util-linux}/bin/mount --make-rprivate ${lib.escapeShellArg pool.path}
        fi
      '') cfg.pools;
    };

    boot.kernelModules = [ "kvm" ];
    boot.supportedFilesystems = lib.mkIf hasZfs [ "zfs" ];
    boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
    networking.nftables.enable = true;
    networking.nftables.flushRuleset = lib.mkDefault false;
    # @cc [owner:ghuntley,label:isolation] lilly-uplink-network-ownership
    # Host network managers MUST leave Lilly's managed uplink addresses alone;
    # they must not add DHCP or IPv6 configuration to the isolated router link.
    networking.dhcpcd.denyInterfaces = [ uplink ];
    networking.networkmanager.unmanaged = [ "interface-name:${uplink}" ];
    systemd.network.networks."10-lilly-unmanaged" = {
      matchConfig.Name = uplink;
      linkConfig.Unmanaged = true;
    };
    networking.firewall.extraForwardRules = lib.mkIf config.networking.firewall.filterForward ''
      iifname "${uplink}" oifname "${cfg.egressInterface}" ip saddr 169.254.255.2 ct state { new, established, related } accept
    '';
    # Boot-time ownership follows the service user: tmpfiles adjusts existing
    # directories, so root here would undo lilly-ownership on every boot.
    systemd.tmpfiles.rules = lib.optional audiConnector "d /run/lilly-ingress 2750 ${serviceUser} audi -" ++ map (path: "d ${path} 0700 ${serviceUser} ${serviceUser} -") [
      "/var/lib/lilly" cfg.stateDirectory cfg.vmStateDirectory cfg.networkStateDirectory
    ];
    systemd.slices.lilly = {
      description = "Independently supervised Firecracker guests";
      wantedBy = [ "multi-user.target" ];
      # Capacity tuning applies properties in place; restarting this slice kills guests.
      unitConfig.X-RestartIfChanged = false;
      sliceConfig = {
        CPUAccounting = true;
        MemoryAccounting = true;
        IOAccounting = true;
        TasksAccounting = true;
        CPUQuota = "${toString (cfg.guestCpuCores * 100)}%";
        MemoryMax = "${toString cfg.guestMemoryMiB}M";
      };
    };
    # This trusted prerequisite has no user data or network interface. It boots
    # both virtualization layers once per host boot before Lilly starts. A failed
    # probe withholds Inception without preventing ordinary profile service.
    systemd.services.lilly-inception-preflight = lib.mkIf (cfg.inceptionImageId != null) {
      wantedBy = [ "multi-user.target" ];
      before = [ "lilly.service" ];
      restartIfChanged = false;
      serviceConfig = let
        input = pkgs.writeText "inception-preflight.json" (builtins.toJSON {
          image_id = cfg.inceptionImageId;
          probe = packages.inceptionProbeGuest;
          release = cfg.package;
        });
        script = ../artifacts/guest/nesting-probe;
      in {
        Type = "oneshot";
        RemainAfterExit = true;
        UMask = "0077";
        RuntimeDirectory = "lilly-inception";
        RuntimeDirectoryMode = "0700";
        StateDirectory = "lilly-inception-check";
        StateDirectoryMode = "0700";
        ExecStart = "${pkgs.python3}/bin/python3 ${script}/host.py ${input}";
        ExecStopPost = "${pkgs.python3}/bin/python3 ${script}/host.py --cleanup";
        TimeoutStartSec = 300;
        TimeoutStopSec = 15;
        KillMode = "control-group";
        CPUQuota = "200%";
        MemoryMax = "4G";
        TasksMax = 128;
        PrivateNetwork = true;
        NoNewPrivileges = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        DevicePolicy = "closed";
        DeviceAllow = [ "/dev/kvm rw" ];
        RestrictAddressFamilies = [ "AF_UNIX" ];
      };
    };
    # @cc [owner:ghuntley,label:security;recovery] hostd-unit-custody
    # lilly-hostd MUST be ready (Type=notify) before Lilly starts, resolve
    # utilities from Lilly's exact PATH, keep command custody in its delegated
    # cgroup, permit lock directories only beneath Lilly's runtime, state and
    # pool roots, admit only root peers from the configured cgroups, and stop
    # Lilly whenever it stops (ADR-0176 decision 4).

    # @cc [owner:ghuntley,label:security] lilly-unprivileged-mode
    # The BEAM MUST run as the `lilly` system user with an empty capability
    # set, with no root mode; lilly-hostd MUST admit exactly that
    # uid; Lilly's state and runtime directories, the files directly in
    # /var/lib/lilly, any socket custody a root Lilly left, each pool's vms,
    # standbys and templates directories and every root-owned sealed
    # template root (the directory alone, readonly restored) MUST be owned
    # by it before Lilly starts (peer groups kept, lock inodes left to
    # hostd); only the pre-start host check, which reads root-only enrollment
    # state, runs elevated; and the uid MUST hold no ZFS delegation on any pool
    # dataset (any found is revoked before Lilly starts). Every root effect,
    # including guest dataset send and receive, stays in hostd (ADR-0183).
    users.users.lilly = {
      isSystemUser = true;
      # Fixed so hostd's peer check and LILLY_SERVICE_UID agree on every host.
      # Below NixOS's dynamic 400-999 system range (which allocated 977 to
      # another service on dungarees) and unassigned in nixpkgs' ids.nix.
      uid = 377;
      group = "lilly";
      description = "Lilly provisioner (unprivileged BEAM)";
    };
    # Root Lilly tools an operator or fixture runs (eval, probes) trust what
    # the service user wrote: Privilege normalises exactly this uid.
    environment.variables.LILLY_SERVICE_UID = serviceUid;
    # Fixed like the uid: hostd chowns lease files to uid:uid (377:377).
    users.groups.lilly.gid = 377;
    systemd.services.lilly-ownership = {
      description = "Hand Lilly's state to its service user";
      wantedBy = [ "multi-user.target" ];
      before = [ "lilly.service" ];
      after = [ "zfs-mount.service" "lilly-pool-propagation.service" ];
      unitConfig.RequiresMountsFor = map (pool: pool.path) cfg.pools;
      path = [ pkgs.coreutils pkgs.findutils pkgs.gnugrep config.boot.zfs.package ];
      serviceConfig = { Type = "oneshot"; RemainAfterExit = true; };
      # State directories are Lilly's alone and handed over recursively. Pools
      # hold guest datasets owned by per-VM uids: only the pool root and
      # Lilly's own .lilly-* metadata trees change owner.
      # Lock inodes (owner.lock) are left alone: lilly-hostd hands each to the
      # service uid itself when it next opens it. Nothing is followed and no
      # file system is crossed.
      script = ''
        handover() {
          find "$1" -xdev ! -name owner.lock -exec chown -h lilly:lilly {} +
        }
      '' + lib.concatMapStringsSep "\n" (directory: ''
        mkdir -p ${lib.escapeShellArg directory}
        chown lilly:lilly ${lib.escapeShellArg directory}
        chmod 0700 ${lib.escapeShellArg directory}
      '') ownedDirectories + ''

        # Lilly's own files directly in /var/lib/lilly (owner.json, the host
        # ownership binding) change owner; its subdirectories are handed over
        # below or hold pools, so nothing deeper is touched here.
        find /var/lib/lilly -xdev -mindepth 1 -maxdepth 1 -type f ! -name owner.lock \
          -exec chown -h lilly:lilly {} +
        # Socket custody a root Lilly left in the shared socket directories:
        # each <socket>.owner claim directory, its claim and the socket it
        # names. Owner only, so the peer service's group stays.
        for sockets in /run/lilly-ingress /run/lilly-brady /run/lilly-inception /run/audi-private /run/ziggy; do
          for custody in "$sockets"/*.owner; do
            [ -d "$custody" ] && [ ! -L "$custody" ] || continue
            find "$custody" -xdev ! -name owner.lock -exec chown -h lilly {} +
            socket="''${custody%.owner}"
            if [ -S "$socket" ]; then chown -h lilly "$socket"; fi
          done
        done
      '' + "\n" + lib.concatMapStringsSep "\n" (directory: ''
        handover ${lib.escapeShellArg directory}
      '') (lib.unique [ "/run/lilly" cfg.stateDirectory cfg.vmStateDirectory cfg.networkStateDirectory ])
        # Transfer keys and export permits a root Lilly wrote (transfers/,
        # exports/) are the BEAM's state too; the root export worker trusts the
        # service uid. Left root-owned, every clone fails at
        # invalid_transfer_identity.
        + lib.optionalString (transferStateDirectory != null) ''

        if [ -d ${lib.escapeShellArg transferStateDirectory} ] && [ ! -L ${lib.escapeShellArg transferStateDirectory} ]; then
          handover ${lib.escapeShellArg transferStateDirectory}
        fi
      ''
        + "\n" + lib.concatMapStringsSep "\n" (pool: ''
        for metadata in ${lib.escapeShellArg pool.path}/.lilly-*; do
          [ -d "$metadata" ] || continue
          if [ "$(basename "$metadata")" = .lilly-jails ]; then
            # Jail trees hold files owned by per-VM uids: hand over only the
            # directories Lilly itself creates entries in.
            chown lilly:lilly "$metadata"
            for jails in "$metadata"/*; do [ -d "$jails" ] && chown lilly:lilly "$jails"; done
            for jail in "$metadata"/*/*; do
              [ -d "$jail" ] && chown lilly:lilly "$jail"
              [ -d "$jail/root" ] && chown lilly:lilly "$jail/root"
            done
          else
            handover "$metadata"
          fi
        done
        # Mountpoint parents a root Lilly created: guest and template datasets
        # mount beneath them, so only each directory itself changes owner (and
        # becomes private, as Lilly requires).
        for parent in vms standbys templates; do
          entry=${lib.escapeShellArg pool.path}/$parent
          if [ -d "$entry" ] && [ ! -L "$entry" ]; then
            chown -h lilly:lilly "$entry"
            chmod 0700 "$entry"
          fi
        done
        # Template roots a root Lilly sealed stay root-owned inside read-only
        # datasets the service user cannot list. Each template child of this
        # pool dataset mounted at its own templates/<id> is mounted and its
        # root directory alone (never a sealed file) is handed over, lifting
        # readonly only around that one chown.
        zfs list -H -o name,mountpoint,readonly,mounted -d 1 ${lib.escapeShellArg pool.storage.dataset} 2>/dev/null |
          while IFS="$(printf '\t')" read -r name mountpoint readonly mounted; do
            case "$name" in ${lib.escapeShellArg pool.storage.dataset}/template-*) ;; *) continue ;; esac
            id="''${name##*/template-}"
            if [ "$mountpoint" != ${lib.escapeShellArg pool.path}/templates/"$id" ]; then continue; fi
            if [ "$mounted" != yes ] && ! zfs mount "$name"; then continue; fi
            if [ ! -d "$mountpoint" ] || [ -L "$mountpoint" ]; then continue; fi
            if [ "$(stat -c %u "$mountpoint")" != 0 ]; then continue; fi
            if [ "$readonly" = on ]; then zfs set readonly=off "$name"; fi
            status=0
            chown -h lilly:lilly "$mountpoint" || status=$?
            if [ "$readonly" = on ]; then zfs set readonly=on "$name"; fi
            if [ "$status" != 0 ]; then exit "$status"; fi
          done
      '') cfg.pools + "\n" + lib.concatMapStringsSep "\n" (pool: ''
        # lilly holds no ZFS permissions (ADR-0183): revoke any delegation an
        # earlier build granted. An absent pool has none to revoke.
        if zfs allow ${lib.escapeShellArg pool.storage.dataset} 2>/dev/null | grep -q '^[[:space:]]*user lilly '; then
          zfs unallow -u lilly ${lib.escapeShellArg pool.storage.dataset}
        fi
      '') cfg.pools;
    };

    systemd.services.lilly-hostd = {
      description = "Lilly host-effects engine";
      wantedBy = [ "multi-user.target" ];
      before = [ "lilly.service" ];
      after = [ "systemd-tmpfiles-setup.service" ];
      unitConfig.RequiresMountsFor = map (pool: pool.path) cfg.pools ++ [
        cfg.stateDirectory cfg.vmStateDirectory cfg.networkStateDirectory
      ];
      path = utilityPath;
      serviceConfig = {
        Type = "notify";
        NotifyAccess = "main";
        ExecStart = lib.escapeShellArgs ([
          "${cfg.package}/host-tools/bin/lilly-hostd"
          "--socket" hostdSocket
          "--cgroup" "self"
          "--peer-uid" serviceUid
        ] ++ lib.concatMap (root: [ "--root" root ]) hostdRoots
          ++ lib.concatMap (pool: [ "--socket-root" pool.path ]) cfg.pools
          ++ lib.concatMap (root: [ "--file-root" root ]) fileRoots
          # ZFS mutations stay strictly beneath these (zfs-arguments-within-pools).
          ++ lib.concatMap (pool: [ "--pool-dataset" pool.storage.dataset ]) cfg.pools
          # Typed VM launches: hostd builds the unit command line from these
          # trusted paths, never from Lilly (vm-launch-argv-derived-by-hostd).
          ++ [
            "--vm-boot-log" "${cfg.package}/host-tools/bin/lilly-boot-log"
            "--vm-unshare" "${cfg.package}/host-tools/bin/unshare"
            "--vm-launch-guard" "${cfg.package}/host-tools/bin/lilly-launch-guard"
            "--vm-jailer" "${packages.vmm}/bin/jailer"
            "--vm-firecracker" "${packages.vmm}/bin/firecracker"
          ]
          ++ lib.concatMap (group: [ "--peer-cgroup" group ]) cfg.hostd.peerCgroups);
        User = "root";
        Group = "root";
        UMask = "0077";
        RuntimeDirectory = "lilly-hostd";
        # `lilly` must reach the socket hostd hands to it
        # (hostd-socket-owned-by-peer); the directory stays unlistable.
        RuntimeDirectoryMode = "0711";
        Delegate = true;
        KillMode = "control-group";
        Restart = "always";
        RestartSec = 1;
        TimeoutStopSec = 30;
        LimitNOFILE = 65536;
      } // hardening;
    };
    systemd.services.lilly = {
      description = "Lilly Firecracker provisioner";
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" "lilly.slice" ] ++ lib.optional (cfg.inceptionImageId != null) "lilly-inception-preflight.service";
      after = [ "network-online.target" "lilly.slice" "systemd-tmpfiles-setup.service" "nftables.service" "lilly-inception-preflight.service" "lilly-hostd.service" ] ++ cfg.secretUnits;
      requires = cfg.secretUnits ++ lib.optional hasZfs "lilly-pool-propagation.service"
        ++ [ "lilly-ownership.service" ];
      # Every lease lives in hostd: Lilly cannot outlive its session.
      bindsTo = [ "lilly-hostd.service" ];
      unitConfig.RequiresMountsFor = map (pool: pool.path) cfg.pools ++ [
        cfg.stateDirectory cfg.vmStateDirectory cfg.networkStateDirectory
      ];
      startLimitIntervalSec = 60;
      startLimitBurst = 5;
      # @cc [owner:ghuntley,label:deployment] zfs-userspace-matches-host-kernel
      # Native ZFS operations MUST resolve the NixOS host's selected ZFS userspace
      # before the application bundle's generic tools. Import/mount setup belongs to
      # the machine specification; service startup MUST NOT create or repartition pools.
      path = utilityPath;
      environment = {
        LILLY_CONFIG_FILE = "/run/lilly-release/config.json";
        LILLY_STATUS_SOCKET = "/run/lilly-release/status.sock";
        LILLY_HOSTD_SOCKET = hostdSocket;
        LILLY_SERVICE_UID = serviceUid;
        RELEASE_DISTRIBUTION = "none";
        RELEASE_TMP = "/run/lilly-release";
        ERL_CRASH_DUMP = "/dev/null";
      };

      # @cc [owner:ghuntley,label:security] lilly-private-runtime-configuration
      # Configuration MUST be atomically published as root-only runtime data,
      # referencing the private credential file and packaged canonical tools.
      preStart = ''
        ${pkgs.jq}/bin/jq --slurpfile metadata ${cfg.package}/overalls-release.json \
          ${lib.optionalString audiConnector ''--argjson audi_uid "$(${pkgs.coreutils}/bin/id -u audi)"''} \
          ${lib.optionalString hasBrady ''--argjson brady_uid "$(${pkgs.coreutils}/bin/id -u brady)"''} \
          '.execution += ($metadata[0] | {firecracker, jailer, unshare})${lib.optionalString audiConnector " | .ingress.audi_uid = $audi_uid"}${lib.optionalString hasBrady " | .execution.brady.uid = $brady_uid"}' \
          ${configuration} > /run/lilly-release/config.json.new
        chmod 0600 /run/lilly-release/config.json.new
        mv -T /run/lilly-release/config.json.new /run/lilly-release/config.json
      '';
      # @cc [owner:ghuntley,label:security] lilly-cookie-argument-alphabet
      # The generated cookie MUST contain only hexadecimal digits so erlexec cannot
      # interpret a leading base64 '+' as a VM flag or echo it in usage diagnostics.
      script = ''
        export RELEASE_COOKIE
        RELEASE_COOKIE="$(${pkgs.coreutils}/bin/head -c 32 /dev/urandom | ${pkgs.coreutils}/bin/basenc --base16 -w0)"
        exec ${dumps.launch cfg.crashDumps cfg.package "/var/lib/lilly-crash-dumps" "${cfg.package}/bin/lilly start"}
      '';
      serviceConfig = {
        StateDirectory = lib.optional cfg.crashDumps.enable "lilly-crash-dumps";
        StateDirectoryMode = "0700";
        ExecStopPost = lib.optional cfg.crashDumps.enable (dumps.finish "/var/lib/lilly-crash-dumps");
        Type = "exec";
        User = serviceUser;
        Group = serviceUser;
        UMask = "0077";
        RuntimeDirectory = "lilly-release";
        RuntimeDirectoryMode = "0700";
        WorkingDirectory = cfg.package;
        Restart = "on-failure";
        RestartSec = 5;
        TimeoutStopSec = 45;
        KillMode = "control-group";
        LimitNOFILE = 65536;
      } // hardening // {
        LoadCredential = loadCredentials;
        CapabilityBoundingSet = "";
        AmbientCapabilities = "";
        NoNewPrivileges = true;
      };
    };
  };
}
