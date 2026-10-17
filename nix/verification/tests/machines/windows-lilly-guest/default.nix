{ pkgs, packages, guest ? packages.windowsGuest, agents ? false }:
# @cc [owner:ghuntley,label:verification;isolation] windows-lilly-guest-reachable-without-agents
# This machine test MUST place the Windows image through the real Lilly driver
# (jailer, seccomp, network guard, ZFS dataset) on nested KVM and pass only when
# the firmware bundle is materialized, the guest configured the delivered /32
# from MMDS so the host reaches it, and the serial log shows the Windows SAC
# prompt. For the agentless image trust MUST be recorded as skipped and
# provisioning MUST reach `unattested` without a readiness receipt, and the test
# MUST NOT claim guest_ready, terminals or workspace delivery. For the
# `windows-v1` image (`agents = true`) trust MUST be recorded as `installed` by
# the guest's trust daemon, provisioning MUST reach `ready` with a boot UUID the
# guest's readiness daemon reported over vsock within the agent set's budget,
# the jail MUST carry the vsock device, and a restart MUST yield a different
# boot UUID. The agents composition also reads the closed agentd startup line
# from the live guest's EFI log; it proves the Windows executor task launches,
# without claiming a Marshall context turn or provider transport.
pkgs.testers.runNixOSTest {
  name = if agents then "overalls-windows-lilly-guest-agents" else "overalls-windows-lilly-guest";
  requiredFeatures.nested-kvm = true;
  # Windows under nested KVM is slow; the image build happens before the test.
  globalTimeout = 14400;
  nodes.storage = { config, lib, ... }: {
    imports = [ (import ../../../../domains/system/lilly.nix { inherit packages; }) ];
    system.stateVersion = "26.05";
    networking.hostId = "aabbccdd";
    boot.supportedFilesystems = [ "zfs" ];
    systemd.services.zfs-zed.enable = false;
    virtualisation.memorySize = 8192;
    virtualisation.cores = 4;
    # Two mirrored members; the Windows root template is a 64 GiB sparse disk.
    virtualisation.emptyDiskImages = map (_: {
      size = 98304;
      driveConfig.driveExtraOpts.cache = "writeback";
    }) [ 1 2 ];
    virtualisation.qemu.forceAccel = lib.mkForce true;
    virtualisation.qemu.options = [ "-cpu host" ];
    boot.extraModprobeConfig = "options zfs zfs_arc_max=536870912";
    services.lilly = {
      firecrackerLogging.enable = true;
      enable = true;
      # Non-empty roots make Driver.trust take the agentless skip path rather
      # than the host-wide "no roots" shortcut.
      guestTrustRoots = [ ../../fixtures/ubuntu/ca.crt ];
      hostId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
      controlPlane = "https://localhost:4443";
      credentialFile = "/run/windows-test-credential.json";
      egressInterface = "eth1";
      guestCpuCores = 2;
      guestMemoryMiB = 3072;
      pools = [{
        id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
        path = "/pool";
        filesystem_id = "zfs:123:456";
        storage = { dataset = "tank/lilly"; dataset_guid = "456"; zpool_guid = "123"; };
      }];
    };
    # The real module's host prerequisites; an isolated API worker drives the VM.
    systemd.services.lilly.enable = false;
    systemd.services.lilly-transfer-sshd.enable = lib.mkForce false;
    environment.etc."windows-lilly.exs".source = ./probe.exs;
    environment.systemPackages = [ config.boot.zfs.package packages.lilly pkgs.jq pkgs.iproute2 pkgs.iputils pkgs.netcat-openbsd pkgs.mtools pkgs.util-linux pkgs.nftables
      (pkgs.writeShellScriptBin "windows-lilly" ''
        export PATH="/run/current-system/sw/bin:${packages.lilly}/host-tools/bin"
        export ERL_FLAGS="+S 2:2"
        export RELEASE_COOKIE="isolated-windows-lilly-cookie"
        export RELEASE_DISTRIBUTION="none"
        export RELEASE_TMP="/run/windows-lilly-release"
        mkdir -p "$RELEASE_TMP"
        export WINDOWS_ACTION="$1"
        export WINDOWS_GENERATION="''${2:-1}"
        export WINDOWS_AGENTS="${if agents then "windows-v1" else "none"}"
        export WINDOWS_GUEST_IMAGE="${guest}"
        export WINDOWS_GUEST_TRUST_ROOTS="${lib.concatStringsSep "," (map (path: toString (pkgs.runCommand "windows-fixture-guest-root.pem" {} ''cp ${path} "$out"'')) config.services.lilly.guestTrustRoots)}"
        export WINDOWS_RELEASE_METADATA="${packages.lilly}/overalls-release.json"
        exec ${packages.lilly}/bin/lilly eval 'Code.eval_file("/etc/windows-lilly.exs")'
      '')
    ];
  };
  testScript = ''
    agents = ${if agents then "True" else "False"}
  '' + builtins.readFile ./driver.py;
}
