{ pkgs, packages }:
let
  evaluated = (import (pkgs.path + "/nixos/lib/eval-config.nix") {
    system = "x86_64-linux";
    inherit pkgs;
    modules = [
      (import ../../../domains/system/peach.nix { inherit packages; })
      (import ../../../domains/system/lilly.nix { inherit packages; })
      (import ../../../domains/system/secrets/default.nix { inherit packages; })
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
let
  service = evaluated.systemd.services.peach;
  runtime = builtins.fromJSON (builtins.readFile service.environment.PEACH_CONFIG_FILE);
in
assert service.serviceConfig.User == "peach";
assert builtins.elem "overalls-secrets-peach.service" service.requires;
assert !(builtins.elem "lilly.service" service.requires);
assert runtime == {
  version = 1;
  host_id = "11111111-1111-4111-8111-111111111111";
  control_plane = "https://control.example.invalid";
  ca_file = "/run/peach/credentials/ca.pem";
  credential_file = "/run/peach/credentials/control.token";
  socket = "/run/peach/reflection.sock";
};
assert builtins.elem "peach-proxy" evaluated.users.users.audi.extraGroups;
assert evaluated.services.overallsSecrets.bundles.peach.outputs."control.token".secrets == [ "PEACH_CREDENTIAL" ];
assert service.serviceConfig.RuntimeDirectory == "peach";
assert evaluated.services.peach.socket == "/run/peach/reflection.sock";
pkgs.runCommand "peach-service-evaluation" {} "touch $out"
