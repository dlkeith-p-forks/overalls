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
  addressFile = "/run/overalls-secrets/fleet-addresses/primary";
  addressUnit = "overalls-fleet-addresses.service";
  runtimeBind = extra: evaluate {
    services.openssh = { enable = true; ports = [ 2222 ]; };
    services.porsche = { bindAddressFile = addressFile; bindAddressUnit = addressUnit; } // extra;
  };
  runtime = runtimeBind {};
  runtimeUnit = runtime.systemd.services.porsche;
  typeRejected = extra: !(builtins.tryEval (builtins.deepSeq (runtimeBind extra).services.porsche.bindAddressFile true)).success;
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
# Static binds keep the store configuration and no address credential.
assert ready.services.porsche.bindAddress == "0.0.0.0";
assert lib.hasPrefix "/nix/store/" ready.systemd.services.porsche.environment.PORSCHE_CONFIG_FILE;
assert !(lib.hasInfix "overalls_bind_address" ready.systemd.services.porsche.preStart);

# @cc [owner:ghuntley,label:verification;security] porsche-runtime-bind-configuration-check
# A runtime bind MUST follow its publishing unit, receive the address only as
# a credential, render a private runtime configuration and refuse ambiguous,
# store-backed or firewall-opening declarations.
assert valid runtime;
assert runtime.services.porsche.bindAddress == null;
assert builtins.elem addressUnit runtimeUnit.after && builtins.elem addressUnit runtimeUnit.requires;
assert builtins.elem "bind-address:${addressFile}" runtimeUnit.serviceConfig.LoadCredential;
assert runtimeUnit.environment.PORSCHE_CONFIG_FILE == "/run/porsche/config.json";
assert lib.all (fragment: lib.hasInfix fragment runtimeUnit.preStart) [
  ''bind_address="$(overalls_bind_address "$CREDENTIALS_DIRECTORY/bind-address")"''
  "'.bind = $bind'"
  "/run/porsche/config.json.new"
];
assert !(lib.hasInfix "198.51.100" runtimeUnit.preStart);
assert !valid (runtimeBind { bindAddress = "198.51.100.5"; });
assert !valid (runtimeBind { bindAddressUnit = null; });
assert !valid (runtimeBind { openFirewall = true; });
assert !valid (evaluate { services.openssh = { enable = true; ports = [ 2222 ]; }; services.porsche.bindAddressUnit = addressUnit; });
assert typeRejected { bindAddressFile = "/var/lib/porsche/address"; };
assert typeRejected { bindAddressFile = "/nix/store/address"; };
assert typeRejected { bindAddressFile = "/run/address:other"; };
assert typeRejected { bindAddressFile = "/run/../etc/address"; };
pkgs.runCommand "porsche-configuration-check" {} ''touch "$out"''
