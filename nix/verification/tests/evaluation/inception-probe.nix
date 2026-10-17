{ pkgs }:
let
  inherit (pkgs) lib;
  probe = import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    modules = [
      ../../../domains/artifacts/guest/configuration.nix
      ../../../domains/artifacts/guest/nesting-probe/minimal.nix
    ];
  };
  config = probe.config;
  absent = name:
    !(builtins.any (package: lib.getName package == name)
      config.environment.systemPackages);
in
# @cc [owner:ghuntley,label:verification;security] inception-probe-evaluation
# Evaluation MUST prove the internal nesting artifact keeps readiness but omits
# the user guest's development, container, SSH and terminal-session surfaces.
assert config.systemd.services.lilly-readiness.wantedBy == [ "multi-user.target" ];
assert absent "devenv" && absent "direnv" && absent "podman-compose";
assert !config.virtualisation.podman.enable;
assert !config.services.openssh.enable;
assert config.networking.firewall.allowedTCPPorts == [ ];
assert !config.systemd.services.lilly-terminals.enable;
pkgs.writeText "inception-probe-evaluation" "passed\n"
