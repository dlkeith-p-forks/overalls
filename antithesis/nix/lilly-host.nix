{ nixpkgs, packages, guest, privateServices ? false }:
let
  lib = nixpkgs.lib;
  system = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ ({ config, pkgs, ... }:
      let
        faultWorker = pkgs.runCommand "overalls-inner-guest-fault-worker" {} ''
          mkdir -p "$out"
          cp ${../integration/crash.py} "$out/crash.py"
          cp ${../integration/fault_worker.py} "$out/fault_worker.py"
          cp ${../integration/witness_worker.py} "$out/witness_worker.py"
        '';
      in {
      # @cc [owner:ghuntley,label:verification;storage] integrated-host-measured-pool
      # This TCG host MUST start the real Lilly Collector, ZFS I/O sampler and
      # pool validator only after a retained ZFS member is verified. Its
      # enrollment and runtime config MUST use the observed GUIDs.
      system.stateVersion = "26.05";
      networking.hostId = "aabbccde";
      networking.hostName = "lilly-host";
      networking.useDHCP = true;
      networking.extraHosts = "10.87.0.11 marshall-a";
      networking.firewall.enable = false;
      boot.kernel.sysctl."net.ipv4.ip_forward" = 1;
      boot.supportedFilesystems = [ "zfs" "9p" ];
      boot.zfs.forceImportRoot = false;
      boot.extraModprobeConfig = "options zfs zfs_arc_max=134217728";
      boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_blk" "virtio_net" "9p" "9pnet_virtio" "ext4" ];
      boot.kernelParams = [ "console=ttyS0" "reboot=k" "panic=1" "net.ifnames=0" "zfs.zfs_arc_max=134217728" ];
      boot.loader.grub.enable = false;
      systemd.services.zfs-zed.enable = false;
      fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
      # A private runtime volume belongs to the outer VM owner. QEMU passes it
      # through to root inside the guest; neither bytes nor paths enter Nix.
      fileSystems."/run/overalls-secrets" = {
        device = "overalls-secrets";
        fsType = "9p";
        options = [ "trans=virtio" "version=9p2000.L" "msize=262144" ];
      };
      fileSystems."/run/overalls-observation" = {
        device = "overalls-observation";
        fsType = "9p";
        options = [ "trans=virtio" "version=9p2000.L" "msize=262144" ];
      };
      fileSystems."/run/overalls-faults" = {
        device = "overalls-faults";
        fsType = "9p";
        options = [ "trans=virtio" "version=9p2000.L" "msize=262144" ];
      };
      environment.systemPackages = [
        pkgs.python313 pkgs.coreutils pkgs.jq pkgs.openssl pkgs.util-linux
        pkgs.iproute2 pkgs.qemu pkgs.vhost-device-vsock config.boot.zfs.package
        packages.lilly packages.hostTools guest.runner guest.server
      ];
      environment.etc."overalls-lilly-release.json".source = "${packages.lilly}/overalls-release.json";
      environment.etc."overalls-host-guest-image-path".text = toString guest.image;
      systemd.services.lilly-guest-emulator = {
        description = "Bounded TCG guest execution peer for integrated Lilly";
        wantedBy = [ "multi-user.target" ];
        requires = [ "lilly-host-pool.service" ];
        after = [ "lilly-host-pool.service" ];
        before = [ "lilly.service" ];
        unitConfig.RequiresMountsFor = [ "/pool" ];
        serviceConfig = {
          ExecStart = "${guest.server}/bin/overalls-tcg-guest-server --socket /run/overalls-guest-vmm/control.sock --witness-socket /run/overalls-guest-witness/witness.sock --tools ${guest.toolConfig} --state-root /pool/guest-emulator --socket-root /run/overalls-tcg";
          Slice = "lilly.slice";
          ExecStartPre = "${pkgs.coreutils}/bin/mkdir -p -m 0700 /pool/guest-emulator /run/overalls-guest-vmm /run/overalls-guest-witness /run/overalls-tcg";
          Restart = "always";
          RestartSec = 3;
          UMask = "0077";
        };
      };
      systemd.services.lilly-host-pool = {
        description = "Verify retained ZFS member and publish measured enrollment";
        wantedBy = [ "multi-user.target" ];
        wants = [ "network-online.target" ];
        after = [ "network-online.target" "run-overalls\\x2dsecrets.mount" ];
        requires = [ "run-overalls\\x2dsecrets.mount" ];
        before = [ "lilly.service" ];
        path = [ config.boot.zfs.package pkgs.util-linux pkgs.coreutils pkgs.openssl ];
        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecStart = "${pkgs.python313}/bin/python3 ${../emulation/host/bootstrap.py} prepare";
          TimeoutStartSec = 240;
          UMask = "0077";
        };
      };
      # @cc [owner:ghuntley,label:capacity;verification] inner-emulated-capacity-slice
      # Lilly and its emulated guest processes MUST share real measured cgroup
      # controllers. Reported limits MUST be kernel-enforced accounting values.
      systemd.slices.lilly = {
        description = "Measured Lilly and emulated guest cgroup";
        wantedBy = [ "multi-user.target" ];
        sliceConfig = {
          CPUAccounting = true;
          MemoryAccounting = true;
          IOAccounting = true;
          TasksAccounting = true;
          CPUQuota = "200%";
          MemoryMax = "5G";
        };
      };
      # @cc [owner:ghuntley,label:security;capacity] integrated-host-credential-gate
      # Lilly MUST start only with a private Marshall-issued credential and
      # exact measured pool identity. Missing or stale ingress leaves it down.
      systemd.services.lilly = {
        description = "Production Lilly on the measured emulated ZFS host";
        wantedBy = [ "multi-user.target" ];
        requires = [ "lilly-host-pool.service" "lilly-guest-emulator.service" ];
        wants = [ "network-online.target" ];
        after = [ "lilly-host-pool.service" "lilly-guest-emulator.service" "network-online.target" ];
        # Keep the selected NixOS ZFS userspace ahead of release host tools.
        path = [ config.boot.zfs.package packages.hostTools pkgs.python313 pkgs.coreutils pkgs.openssl pkgs.jq ];
        environment = {
          LILLY_CONFIG_FILE = "/run/lilly-host/config.json";
          LILLY_STATUS_SOCKET = "/run/lilly-host/status.sock";
          OVERALLS_TCG_GUEST_TOOLS = "${guest.toolConfig}";
          OVERALLS_ANTITHESIS_GUEST_SOCKET = "/run/overalls-guest-vmm/control.sock";
          OVERALLS_ANTITHESIS_GUEST_SOCKET_ROOT = "/run/overalls-tcg";
          RELEASE_DISTRIBUTION = "none";
          RELEASE_TMP = "/run/lilly-host";
          ERL_CRASH_DUMP = "/dev/null";
          ERL_FLAGS = "+S 2:2";
        };
        serviceConfig = {
          Slice = "lilly.slice";
          RuntimeDirectory = "lilly-host";
          RuntimeDirectoryMode = "0700";
          UMask = "0077";
          ExecStartPre = "${pkgs.python313}/bin/python3 ${../emulation/host/bootstrap.py} activate${lib.optionalString privateServices " --private-services"}";
          ExecStart = "${pkgs.writeShellScript "overalls-lilly-host-launch" ''
            export RELEASE_COOKIE="$(${pkgs.openssl}/bin/openssl rand -hex 32)"
            exec ${packages.lilly}/bin/lilly start
          ''}";
          Restart = "on-failure";
          RestartSec = 5;
          TimeoutStartSec = 240;
        };
      };
      systemd.services.lilly-host-health = {
        description = "Publish live measured host and authenticated Control readiness";
        wantedBy = [ "multi-user.target" ];
        requires = [ "lilly-host-pool.service" ];
        after = [ "lilly-host-pool.service" ];
        path = [ config.boot.zfs.package pkgs.util-linux pkgs.coreutils ];
        unitConfig.AssertPathIsMountPoint = "/run/overalls-observation";
        serviceConfig = {
          ExecStart = "${pkgs.python313}/bin/python3 ${../emulation/host/bootstrap.py} monitor";
          Restart = "always";
          RestartSec = 3;
          UMask = "0077";
        };
      };
      # @cc [owner:ghuntley,label:verification;security] inner-guest-crash-worker
      # The private spool MUST be mounted separately from public observations.
      # A crash request may target only a recorded live guest process identity.
      systemd.services.lilly-host-faults = {
        description = "Closed guest process crash actuator";
        wantedBy = [ "multi-user.target" ];
        requires = [ "lilly-host-pool.service" "lilly-guest-emulator.service" ];
        after = [ "lilly-host-pool.service" "lilly-guest-emulator.service" ];
        unitConfig.RequiresMountsFor = [ "/pool" "/run/overalls-faults" ];
        unitConfig.AssertPathIsMountPoint = "/run/overalls-faults";
        serviceConfig = {
          ExecStart = "${pkgs.python313}/bin/python3 ${faultWorker}/fault_worker.py --spool /run/overalls-faults --state-root /pool/guest-emulator --qemu ${guest.qemu}/bin/qemu-system-x86_64";
          Restart = "always";
          RestartSec = 3;
          UMask = "0077";
        };
      };
      systemd.services.lilly-host-witness = {
        description = "Read-only guest observation transport";
        wantedBy = [ "multi-user.target" ];
        requires = [ "lilly-guest-emulator.service" ];
        after = [ "lilly-guest-emulator.service" ];
        unitConfig.RequiresMountsFor = [ "/run/overalls-faults" ];
        unitConfig.AssertPathIsMountPoint = "/run/overalls-faults";
        serviceConfig = {
          ExecStart = "${pkgs.python313}/bin/python3 ${faultWorker}/witness_worker.py --spool /run/overalls-faults --socket /run/overalls-guest-witness/witness.sock";
          Restart = "always";
          RestartSec = 3;
          UMask = "0077";
        };
      };
    }) ] ++ lib.optional privateServices (import ./lilly-private.nix { inherit packages; });
  };
  pkgs = system.pkgs;
  rootImage = import "${nixpkgs}/nixos/lib/make-disk-image.nix" {
    inherit pkgs lib;
    config = system.config;
    format = "qcow2";
    partitionTableType = "none";
    installBootLoader = false;
    copyChannel = false;
    additionalSpace = "512M";
    baseName = "overalls-lilly-host";
  };
in {
  inherit system rootImage;
  qemu = pkgs.qemu;
  kernel = system.config.system.build.kernel;
  initrd = system.config.system.build.initialRamdisk;
  toplevel = system.config.system.build.toplevel;
}
