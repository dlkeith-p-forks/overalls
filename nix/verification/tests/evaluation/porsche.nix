{ pkgs, module }:
let
  inherit (pkgs) lib;
  evaluate = extra: (import (pkgs.path + "/nixos/lib/eval-config.nix") {
    inherit pkgs;
    system = pkgs.stdenv.hostPlatform.system;
    modules = [ module {
      system.stateVersion = "26.05";
      boot.loader.grub.enable = false;
      fileSystems."/" = { device = "/dev/vda"; fsType = "ext4"; };
      services.porsche = {
        enable = true;
        controlPlane = "https://control.example.test";
        publicOrigin = "https://control.example.test";
        credentialFile = "/run/private/gateway.token";
      };
    } extra ];
  }).config;
  valid = config: lib.all (item: item.assertion) config.assertions;
  ready = evaluate { services.openssh = { enable = true; ports = [ 2222 ]; }; };
  absent = evaluate {};
  console = evaluate { services.porsche.administrativeAccess = "console"; };
  consoleWithSSH = evaluate {
    services.porsche.administrativeAccess = "console";
    services.openssh = { enable = true; ports = [ 2222 ]; };
  };
  overlapping = evaluate { services.openssh.enable = true; };
  custom = evaluate { services.porsche.port = 2200; services.openssh.enable = true; };
in
# @cc [owner:ghuntley,label:verification] porsche-administrative-port-precondition
# Physical-host defaults MUST require administrative OpenSSH on 2222 for port
# 22 management. Explicit console-only mode MUST instead forbid OpenSSH. All
# modes MUST reject listener collisions. Port changes alone do not prove that
# an operator can authenticate; staged deployment acceptance remains separate.
assert valid ready;
assert !valid absent;
assert valid console;
assert !valid consoleWithSSH;
assert !valid overlapping;
assert valid custom;
assert ready.systemd.services.porsche.serviceConfig.User == "porsche";
assert ready.systemd.services.porsche.serviceConfig.LoadCredential == [
  "gateway.token:/run/private/gateway.token"
  "ca.pem:${pkgs.cacert}/etc/ssl/certs/ca-bundle.crt"
];
pkgs.runCommand "porsche-configuration-check" {} ''touch "$out"''
