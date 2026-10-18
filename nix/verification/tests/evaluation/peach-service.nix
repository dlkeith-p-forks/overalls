{ pkgs, packages }:
let
  evaluated = (import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    inherit pkgs;
    modules = [
      (import ../../../domains/system/peach.nix { inherit packages; })
      (import ../../../domains/system/lilly.nix { inherit packages; })
      ({ lib, ... }: {
        services.lilly = {
          enable = true;
          hostId = "11111111-1111-4111-8111-111111111111";
          controlPlane = "https://control.example.invalid";
          controlPlaneCAFile = "/etc/ssl/ca.pem";
        };
        services.peach = {
          enable = true;
          secretsFile = "/run/secrets/peach.yaml";
        };
      })
    ];
  }).config;
in
assert evaluated.systemd.services.peach.serviceConfig.User == "peach";
assert evaluated.systemd.services.peach.serviceConfig.RuntimeDirectory == "peach";
assert evaluated.services.peach.socket == "/run/peach/reflection.sock";
pkgs.runCommand "peach-service-evaluation" {} "touch $out"
