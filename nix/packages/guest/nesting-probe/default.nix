{ image }:
{ pkgs, ... }:
let
  configuration = pkgs.writeText "nested-firecracker-probe.json" (builtins.toJSON {
    inherit image;
    firecracker = "${pkgs.pkgsStatic.firecracker}/bin/firecracker";
    modprobe = "${pkgs.kmod}/bin/modprobe";
    ip = "${pkgs.iproute2}/bin/ip";
    readiness_source = ../.;
  });
in {
  boot.kernelModules = [ "kvm" ];
  systemd.services.nested-firecracker-probe = {
    wantedBy = [ "multi-user.target" ];
    serviceConfig = {
      Type = "exec";
      UMask = "0077";
      ExecStart = "${pkgs.python3}/bin/python3 ${./.}/guest.py ${configuration}";
    };
  };
}
