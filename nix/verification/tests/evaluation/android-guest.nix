{ pkgs, packages }:
let
  image = packages.androidGuest;
  manifest = builtins.fromJSON (builtins.unsafeDiscardStringContext (builtins.readFile "${image}/manifest.json"));
  androidModule = import ../../../domains/artifacts/guest/android.nix {
    inherit pkgs;
    androidSdk = packages.androidSdk;
  };
  guest = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    inherit pkgs;
    specialArgs = { codingClis = packages.codingClis; };
    modules = [ ../../../domains/artifacts/guest/configuration.nix androidModule ];
  };
  services = guest.config.systemd.services;
  emulatorScript = builtins.readFile services.overalls-android-emulator.serviceConfig.ExecStart;
in
# @cc [owner:ghuntley,label:verification;isolation] android-guest-image-evaluation
# The production Android image MUST advertise linux-android-v1 and carry the
# software-rendered emulator, loopback RFB server and typed display relay. The
# evaluated service graph is an image-boundary check; it does not claim a live
# Firecracker boot or authenticated browser journey.
assert manifest.guest_agents == "linux-android-v1";
assert services ? overalls-android-emulator;
assert services ? overalls-android-display;
assert services ? overalls-android-display-vsock;
assert builtins.match ".*-no-accel.*" emulatorScript != null;
assert builtins.match ".*-gpu swiftshader_indirect.*" emulatorScript != null;
assert services.overalls-android-display.serviceConfig.ExecStart != null;
assert services.overalls-android-display-vsock.serviceConfig.ExecStart != null;
pkgs.runCommand "android-guest-image-evaluation" { } "touch $out"
