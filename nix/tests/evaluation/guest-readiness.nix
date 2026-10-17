{ pkgs }:
let
  guest = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    inherit pkgs;
    modules = [ ../../packages/guest/configuration.nix ];
  };
  service = guest.config.systemd.services.lilly-readiness;
in
assert builtins.elem "multi-user.target" service.wantedBy;
assert !(builtins.elem "multi-user.target" service.after);
assert builtins.elem "AF_VSOCK" service.serviceConfig.RestrictAddressFamilies;
assert !(builtins.elem "AF_INET" service.serviceConfig.RestrictAddressFamilies);
assert builtins.elem "vmw_vsock_virtio_transport" guest.config.boot.kernelModules;
# guest-nix-store-registration: the image registers its closure at build time.
assert !(guest.config.systemd.services ? register-nix-paths);
assert builtins.all (parameter: builtins.elem parameter guest.config.boot.kernelParams) [ "printk.time=1" "quiet" "systemd.show_status=error" ];
assert guest.config.systemd.services.lilly-boot-report.after == [ "lilly-readiness.service" ];
assert guest.config.systemd.services.lilly-boot-report.requiredBy == [ ];
assert guest.config.systemd.services.lilly-boot-report.serviceConfig.Type == "exec";
# guest-lean-initrd
assert !guest.config.boot.initrd.includeDefaultModules && !guest.config.console.enable;
pkgs.runCommand "lilly-guest-readiness-check" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  export PYTHONDONTWRITEBYTECODE=1
  python3 -W error ${./guest-readiness.py} ${../../packages/guest/readiness.py}
  touch $out
''
