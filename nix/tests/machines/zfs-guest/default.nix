{ pkgs, packages, guest ? packages.guest, ubuntu ? false, backups ? false, namespaceCleanup ? false, cloneMatrix ? false, actorRecovery ? false, bootProfile ? false }:
pkgs.testers.runNixOSTest {
  name = if bootProfile then (if ubuntu then "overalls-ubuntu-guest-boot-profile" else "overalls-guest-boot-profile") else if actorRecovery then "overalls-lilly-native-actor-recovery" else if backups then "overalls-guest-backups" else if namespaceCleanup then "overalls-zfs-namespace-cleanup" else if cloneMatrix then "overalls-zfs-guest-clone" else if ubuntu then "overalls-ubuntu-guest" else "overalls-zfs-guest";
  extraPythonPackages = pythonPackages: pkgs.lib.optionals actorRecovery [ pythonPackages.hypothesis ];
  requiredFeatures.nested-kvm = true;
  # The full NixOS journey reached its last multi-disk case at the old one-hour
  # deadline. Keep individual operation deadlines and every assertion intact.
  globalTimeout = if bootProfile then 1800 else if backups || namespaceCleanup || ubuntu || cloneMatrix then 3600 else 14400;
  nodes.storage = { config, lib, ... }: {
    imports = [ (import ../../../modules/lilly.nix { inherit packages; }) ];
    system.stateVersion = "26.05";
    networking.hostId = "aabbccdd";
    boot.supportedFilesystems = [ "zfs" ];
    systemd.services.zfs-zed.enable = false;
    virtualisation.memorySize = 4096;
    virtualisation.cores = 2;
    virtualisation.emptyDiskImages = map (_: {
      # Sparse backing disks accommodate manifest-derived fixture quotas. The
      # driver bounds that quota below this mirror's physical capacity.
      size = 32768;
      driveConfig.driveExtraOpts.cache = "writeback";
    # The third disk backs a genuinely independent receive-source zpool for
    # the primary clone journey; it never shares the mirror's capacity identity.
    }) [ 1 2 3 ];
    virtualisation.qemu.forceAccel = lib.mkForce true;
    virtualisation.qemu.options = [ "-cpu host" ];
    # Bound fixture memory; this is not a production tuning recommendation.
    boot.extraModprobeConfig = "options zfs zfs_arc_max=536870912";
    services.lilly = {
      firecrackerLogging.enable = true;
      enable = true;
      # The probe BEAM runs outside lilly.service but uses the production
      # lilly-hostd unit, so cgroup custody and the unit's PATH are exercised.
      hostd.peerCgroups = [ ];
      guestTrustRoots = lib.optionals (ubuntu || bootProfile) [ ../../fixtures/ubuntu/ca.crt ];
      hostId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
      controlPlane = "https://localhost:4443";
      credentialFile = "/run/zfs-test-credential.json";
      egressInterface = "eth1";
      guestCpuCores = 2;
      guestMemoryMiB = 1536;
      # API workers below discover the real fixture pool identity at runtime.
      pools = [{
        id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
        path = "/pool";
        filesystem_id = "zfs:123:456";
        storage = { dataset = "tank/lilly"; dataset_guid = "456"; zpool_guid = "123"; };
      }];
    };
    # Use the real module's host prerequisites; isolated API workers drive VMs.
    # There is no control-plane fixture or live credential in this storage test.
    systemd.services.lilly.enable = false;
    systemd.services.lilly-transfer-sshd.enable = lib.mkIf (namespaceCleanup || actorRecovery) (lib.mkForce false);
    environment.etc."zfs-guest.exs".source = ./probe.exs;
    environment.etc."zfs-template-post-import.exs".source = ./template-post-import.exs;
    environment.etc."zfs-coding-clis.py".source = ./coding_clis.py;
    environment.etc."zfs-guest-manifest.json".source = "${guest}/manifest.json";
    # Public roots for the boot-profile trust rotation journey; never keys.
    environment.etc."zfs-trust/fixture-root.pem".source = ../../fixtures/ubuntu/ca.crt;
    environment.etc."zfs-trust/rotation-root.pem".source = ../../../../secrets/brady-root.pem;
    environment.etc."hold-namespace.py".source = ./hold-namespace.py;
    environment.etc."namespace-inventory.py".source = ./namespace-inventory.py;
    environment.etc."zfs-cloning.exs".source = ./cloning.exs;
    environment.etc."zfs-clone-matrix.exs".source = ./clone-matrix.exs;
    environment.etc."zfs-source.exs".source = ./source.exs;
    environment.etc."zfs-readiness.exs".source = ./readiness.exs;
    environment.etc."zfs-restoration.exs".source = ./restoration.exs;
    environment.etc."zfs-restart.exs".source = ./restart.exs;
    environment.etc."zfs-actor-recovery.exs".source = ./actor-recovery.exs;
    environment.etc."zfs-readiness-fault".source = pkgs.writeShellScript "zfs-readiness-fault" ''
      exec ${pkgs.python3}/bin/python3 ${../../support/zfs-readiness-fault.py} ${config.boot.zfs.package}/bin/zfs "$@"
    '';
    environment.etc."backup-zfs-fault".source = pkgs.writeShellScript "backup-zfs-fault" ''
      ${config.boot.zfs.package}/bin/zfs "$@"
      result=$?
      if [ "$result" = 0 ] && [ "$1" = snapshot ]; then
        touch /run/backup-native-created
        exec sleep 300
      fi
      exit "$result"
    '';
    environment.systemPackages = [ config.boot.zfs.package packages.lilly pkgs.jq pkgs.restic pkgs.e2fsprogs pkgs.python3
      (pkgs.writeShellScriptBin "zfs-backup" ''
        export PATH="/run/current-system/sw/bin:${packages.lilly}/host-tools/bin"
        export ERL_FLAGS="+S 2:2" RELEASE_COOKIE="isolated-backup-fixture" RELEASE_DISTRIBUTION=none
        export RELEASE_TMP=/run/zfs-backup-release ERL_CRASH_DUMP=/dev/null
        mkdir -p "$RELEASE_TMP"
        export OVERALLS_BACKUP_CONFIG=/run/backup-config.json
        export OVERALLS_BACKUP_OPERATION="$1" OVERALLS_BACKUP_REQUEST="$2"
        exec ${packages.lilly}/bin/lilly eval 'if System.get_env("BACKUP_FAULT") == "1", do: System.put_env("PATH", "/run/backup-fault/bin:" <> System.fetch_env!("PATH")); Lilly.Backup.main()'
      '')
      (pkgs.writeShellScriptBin "zfs-guest-processes" ''
        exec ${pkgs.python3}/bin/python ${../../support/vm-processes.py} "$@"
      '')
      (pkgs.writeShellScriptBin "zfs-guest" ''
        export PATH="/run/current-system/sw/bin:${packages.lilly}/host-tools/bin"
        export ERL_FLAGS="+S 2:2"
        export RELEASE_COOKIE="isolated-zfs-guest-cookie"
        export RELEASE_DISTRIBUTION="none"
        export RELEASE_TMP="/run/zfs-release"
        mkdir -p "$RELEASE_TMP"
        export ZFS_ACTION="$1"
        export ZFS_GENERATION="''${2:-1}"
        export ZFS_VM="''${3:-101}"
        export ZFS_TARGET="''${4:-0}"
        export ZFS_GUEST_IMAGE="${guest}"
        export ZFS_GUEST_TRUST_ROOTS="''${ZFS_GUEST_TRUST_ROOTS_OVERRIDE:-${lib.concatStringsSep "," (map (path: toString (pkgs.runCommand "zfs-fixture-guest-root.pem" {} ''cp ${path} "$out"'')) config.services.lilly.guestTrustRoots)}}"
        export ZFS_GUEST_UBUNTU="${if ubuntu then "1" else "0"}"
        export ZFS_GUEST_PRIVATE_NIXOS="${if bootProfile && !ubuntu then "1" else "0"}"
        export ZFS_RELEASE_METADATA="${packages.lilly}/overalls-release.json"
        export LILLY_HOSTD_SOCKET=/run/lilly-hostd/control.sock
        exec ${packages.lilly}/bin/lilly eval 'Code.eval_file("/etc/zfs-guest.exs")'
      '')
    ];
  };
  testScript = builtins.readFile ./disk_shape.py + "\n" + (if backups || namespaceCleanup || cloneMatrix || actorRecovery then "" else ''ubuntu_guest_fixture: bool = ${if ubuntu then "True" else "False"}
'') + (if backups || namespaceCleanup || cloneMatrix || actorRecovery then "" else builtins.readFile ./boot_profile.py + "\n")
    + builtins.readFile (if bootProfile then ./boot-profile.py else if actorRecovery then ./actor-recovery.py else if backups then ./backups.py else if namespaceCleanup then ./namespace-cleanup.py else if cloneMatrix then ./clone-matrix.py else ./driver.py);
}
