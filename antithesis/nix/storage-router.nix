{ nixpkgs, packages }:
let
  lib = nixpkgs.lib;
  system = nixpkgs.lib.nixosSystem {
    system = "x86_64-linux";
    modules = [ ({ config, pkgs, ... }:
      let
        python = pkgs.python3.withPackages (p: [ p.cryptography ]);
        fixture = ../emulation/storage;
        origin = ../emulation/storage/origin.py;
        prepare = ../../nix/tests/machines/brady-network/prepare.exs;
      in {
        # @cc [owner:ghuntley,label:verification;storage] router-emulated-kernel-boundary
        # This is a separate TCG Linux/ZFS fixture. It does not replace the
        # KVM-only machine gates or establish physical storage durability.
        system.stateVersion = "26.05";
        networking.hostId = "aabbccdd";
        networking.useDHCP = false;
        networking.firewall.enable = false;
        networking.extraHosts = ''
          8.8.4.4 origin.brady.test tunnel.brady.test codeload.github.com
        '';
        boot.supportedFilesystems = [ "zfs" ];
        boot.zfs.forceImportRoot = false;
        boot.kernelModules = [ "nf_tproxy_ipv4" "nft_tproxy" ];
        boot.initrd.availableKernelModules = [ "virtio_pci" "virtio_blk" "virtio_console" "ext4" ];
        boot.extraModprobeConfig = "options zfs zfs_arc_max=134217728";
        boot.kernelParams = [ "console=ttyS0" "reboot=k" "panic=1" "zfs.zfs_arc_max=134217728" ];
        boot.loader.grub.enable = false;
        systemd.services.zfs-zed.enable = false;
        fileSystems."/" = { device = "/dev/disk/by-label/nixos"; fsType = "ext4"; };
        users.users.brady = { isSystemUser = true; group = "brady"; uid = 991; };
        users.groups.brady = {};
        environment.etc."brady-storage.py".source = ../../nix/modules/brady/storage.py;
        environment.etc."router-network.exs".source = prepare;
        environment.etc."router-origin.py".source = origin;
        environment.systemPackages = [
          python pkgs.iproute2 pkgs.nftables pkgs.util-linux pkgs.procps pkgs.curl pkgs.git
          pkgs.jq pkgs.coreutils pkgs.openssl config.boot.zfs.package
          packages.lilly packages.brady packages.hostTools
        ];
        systemd.services.router-bootstrap = {
          description = "Own and import the retained emulated ZFS mirror and Brady router";
          wantedBy = [ "multi-user.target" ];
          before = [ "brady-pressure.service" "brady-origin.service" "brady.service" "router-control.service" ];
          path = [ python pkgs.iproute2 pkgs.nftables pkgs.util-linux pkgs.procps pkgs.coreutils
                   config.boot.zfs.package packages.lilly ];
          environment = { RELEASE_DISTRIBUTION = "none"; RELEASE_TMP = "/run/router-lilly";
                          ERL_FLAGS = "+S 1:1"; ERL_CRASH_DUMP = "/dev/null"; };
          serviceConfig = {
            Type = "oneshot"; RemainAfterExit = true;
            ExecStart = "${python}/bin/python3 ${fixture}/bootstrap.py ${packages.lilly}/bin/lilly";
            TimeoutStartSec = 240; UMask = "0077";
            StandardOutput = "journal+console"; StandardError = "journal+console";
          };
        };
        systemd.services.brady-pressure = {
          description = "Production Brady native pressure sampler in emulated kernel";
          wantedBy = [ "multi-user.target" ];
          requires = [ "router-bootstrap.service" ];
          after = [ "router-bootstrap.service" ];
          serviceConfig = {
            ExecStart = "${python}/bin/python3 /etc/brady-storage.py /run/brady-storage.json observe";
            Restart = "always"; RestartSec = 5;
            User = "root"; Group = "brady"; UMask = "0027";
            RuntimeDirectory = "brady-pressure"; RuntimeDirectoryMode = "0750";
            NoNewPrivileges = true; ProtectSystem = "strict"; ProtectHome = true;
            PrivateTmp = true; ReadWritePaths = [ "/var/cache/brady" "/pool" ];
            CapabilityBoundingSet = [ "CAP_SYS_ADMIN" "CAP_DAC_READ_SEARCH" ];
            MemoryMax = "64M"; CPUQuota = "100%"; TasksMax = 16;
          };
        };
        systemd.services.brady-origin = {
          description = "Local independent HTTP/TLS origin";
          wantedBy = [ "multi-user.target" ];
          requires = [ "router-bootstrap.service" ];
          after = [ "router-bootstrap.service" ];
          serviceConfig = {
            ExecStart = "${python}/bin/python3 /etc/router-origin.py serve";
            NetworkNamespacePath = "/run/netns/origin";
            Restart = "always"; RestartSec = 3;
          };
        };
        systemd.services.brady = {
          description = "Source-built Brady in isolated Lilly router namespace";
          wantedBy = [ "multi-user.target" ];
          requires = [ "router-bootstrap.service" "brady-pressure.service" ];
          after = [ "router-bootstrap.service" "brady-pressure.service" ];
          environment = { BRADY_CONFIG_FILE = "/run/brady-fixture/config.json";
                          BRADY_FLEET_MONITOR = "1"; RELEASE_DISTRIBUTION = "none";
                          RELEASE_TMP = "/run/brady";
                          ERL_FLAGS = "+S 1:1";
                          ERL_CRASH_DUMP = "/dev/null"; };
          serviceConfig = {
            ExecStart = "${packages.brady}/bin/brady start";
            EnvironmentFile = "/run/router-release-cookie";
            User = "brady"; Group = "brady"; UMask = "0077";
            RuntimeDirectory = "brady"; RuntimeDirectoryMode = "0700";
            NetworkNamespacePath = "/run/netns/lilly-bd7662a5eeb4";
            LoadCredential = [ "issuer.pem:/run/brady-fixture/issuer.pem"
                               "issuer.key:/run/brady-fixture/ca.key" ];
            NoNewPrivileges = true; ProtectSystem = "strict"; ProtectHome = true;
            PrivateTmp = true; ReadWritePaths = [ "/var/cache/brady" ];
            CapabilityBoundingSet = [ "CAP_NET_RAW" ];
            AmbientCapabilities = [ "CAP_NET_RAW" ];
            RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" ];
            MemoryMax = "1G"; CPUQuota = "100%"; TasksMax = 256;
            Restart = "always"; RestartSec = 3;
          };
          preStart = ''
            ${pkgs.coreutils}/bin/install -d -m 0700 -o brady -g brady /run/brady/credentials
            ${pkgs.coreutils}/bin/install -m 0400 "$CREDENTIALS_DIRECTORY/issuer.pem" /run/brady/credentials/issuer.pem
            ${pkgs.coreutils}/bin/install -m 0400 "$CREDENTIALS_DIRECTORY/issuer.key" /run/brady/credentials/issuer.key
          '';
        };
        systemd.services.router-control = {
          description = "Closed typed storage-router control over virtio serial";
          wantedBy = [ "multi-user.target" ];
          requires = [ "router-bootstrap.service" ];
          after = [ "router-bootstrap.service" ];
          path = [ pkgs.systemd pkgs.iproute2 pkgs.nftables pkgs.curl config.boot.zfs.package ];
          serviceConfig = {
            ExecStart = "${python}/bin/python3 ${fixture}/control.py";
            Restart = "always"; RestartSec = 3; UMask = "0077";
            TimeoutStartSec = 30;
          };
        };
      }) ];
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
    baseName = "overalls-storage-router";
  };
in {
  inherit system rootImage;
  inherit (pkgs) qemu;
  kernel = system.config.system.build.kernel;
  initrd = system.config.system.build.initialRamdisk;
  toplevel = system.config.system.build.toplevel;
}
