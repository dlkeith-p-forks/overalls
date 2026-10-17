{ pkgs }:
let
  guest = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    inherit pkgs;
    modules = [ ../../../domains/artifacts/guest/configuration.nix ];
  };
  service = guest.config.systemd.services.lilly-flush;
in
assert service.serviceConfig.RestrictAddressFamilies == [ "AF_VSOCK" ];
assert builtins.elem "multi-user.target" service.wantedBy;
assert service.serviceConfig.TasksMax == 4;
pkgs.runCommand "lilly-guest-flush-check" { nativeBuildInputs = [ pkgs.python3 ]; } ''
  export PYTHONDONTWRITEBYTECODE=1
  python3 -W error ${./guest-flush.py} ${../../../domains/artifacts/guest/flush.py}
  touch $out
''
