{ pkgs, terminald, lyraLinux, vscodeWeb ? null, vscodeWebBroker ? null,
  privateServiceRoots ? [ ], extraModules ? [ ] }:
let
  lib = pkgs.lib;
  observerTerminald = import ../../nix/domains/artifacts/infrastructure/terminald.nix {
    inherit pkgs;
    antithesisObserver = true;
  };
  terminalProbe = import ../guest_observers { inherit pkgs; };
  # @cc [owner:ghuntley,label:verification;isolation] tcg-guest-is-production-guest
  # The emulator image MUST use the production NixOS guest builder and services.
  # Harness changes are limited to q35 boot/network/memory adjustments and the
  # synthetic terminal observer/probe; production terminald remains unchanged.
  image = import ../../nix/domains/artifacts/guest {
    inherit pkgs lyraLinux vscodeWeb vscodeWebBroker privateServiceRoots;
    terminald = observerTerminald;
    imageName = "overalls-antithesis-tcg-nixos-x86_64";
    minimumMemoryBytes = 2147483648;
    extraModules = [ ({ ... }: {
      environment.systemPackages = [ terminalProbe ];
      networking.nameservers = lib.mkForce [ "169.254.254.1" ];
      boot.initrd.availableKernelModules = lib.mkForce [
        "virtio_pci" "virtio_blk" "virtio_net"
        "vmw_vsock_virtio_transport" "ext4"
      ];
      # @cc [owner:ghuntley,label:recovery;isolation] q35-guest-eth0
      # QEMU's PCI NIC MUST retain eth0, the interface required by the real
      # guest network configurator and readiness probes. The native image
      # remains on its existing virtio-mmio boot parameters.
      boot.kernelParams = lib.mkForce [
        "console=ttyS0" "reboot=k" "panic=1" "net.ifnames=0" "systemd.getty_auto=0"
        "printk.time=1" "quiet" "systemd.show_status=error"
      ];
    }) ] ++ extraModules;
  };
  # @cc [owner:ghuntley,label:build;security] pinned-guest-runner-inputs
  # The packaged runner and its static config MUST bind the same pinned image,
  # QEMU, vsock backend and network tool selected by this Nix package set.
  # Placement, generation and physical boot fields remain runtime authority.
  runner = pkgs.writeShellScriptBin "overalls-tcg-guest" ''
    exec ${pkgs.python313}/bin/python3 ${../emulation/guest/runner.py} "$@"
  '';
  # @cc [owner:ghuntley,label:build] guest-control-server-package
  # The inner host and outer guest adapter MUST use the same immutable server
  # and sibling runner sources so request validation cannot drift by topology.
  server = pkgs.runCommand "overalls-tcg-guest-server" {} ''
    mkdir -p "$out/bin" "$out/libexec"
    cp ${../emulation/guest/server.py} "$out/libexec/server.py"
    cp ${../emulation/guest/runner.py} "$out/libexec/runner.py"
    cat > "$out/bin/overalls-tcg-guest-server" <<SERVER
    #!${pkgs.bash}/bin/bash
    exec ${pkgs.python313}/bin/python3 "$out/libexec/server.py" "\$@"
    SERVER
    chmod 0755 "$out/bin/overalls-tcg-guest-server"
  '';
  toolConfig = pkgs.writeText "overalls-tcg-guest-tools.json" (builtins.toJSON {
    image_dir = "${image}";
    qemu = "${pkgs.qemu}/bin/qemu-system-x86_64";
    qemu_img = "${pkgs.qemu}/bin/qemu-img";
    backend = "${pkgs.vhost-device-vsock}/bin/vhost-device-vsock";
    ip = "${pkgs.iproute2}/bin/ip";
  });
in
{
  inherit image runner server toolConfig;
  qemu = pkgs.qemu;
  vsockBackend = pkgs.vhost-device-vsock;
}
