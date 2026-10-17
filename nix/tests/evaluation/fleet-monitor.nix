{ pkgs, module }:
let
  evaluate = extra: (import (pkgs.path + "/nixos/lib/eval-config.nix") {
    inherit pkgs;
    system = pkgs.stdenv.hostPlatform.system;
    modules = [ module {
      system.stateVersion = "26.05";
      boot.loader.grub.enable = false;
      fileSystems."/" = { device = "/dev/vda"; fsType = "ext4"; };
    } extra ];
  }).config;
  disabled = evaluate {};
  enabled = evaluate {
    services.marshall = {
      enable = true;
      publicHost = "control.example.test";
      databaseConnectionBudget = 43;
      instances = {
        one = { port = 4443; certificateFile = "/run/tls/backend.crt"; keyFile = "/run/tls/backend.key"; };
        two = { port = 4444; certificateFile = "/run/tls/backend.crt"; keyFile = "/run/tls/backend.key"; };
        three = { port = 4445; certificateFile = "/run/tls/backend.crt"; keyFile = "/run/tls/backend.key"; };
      };
    };
    services.overallsFleetExporter = {
      enable = true;
      externalInterfaces = [ "eth0" ];
    };
  };
  service = enabled.systemd.services.overalls-fleet-exporter;
in
assert !(disabled.systemd.services ? overalls-fleet-exporter);
assert enabled.services.overallsFleetExporter.roles == [ "marshall" ];
assert enabled.services.overallsFleetExporter.units == [ "marshall-one.service" "marshall-three.service" "marshall-two.service" ];
assert service.requires == [];
assert !(service.serviceConfig ? LoadCredential);
assert enabled.services.overallsFleetExporter.port == 9466;
assert service.serviceConfig.MemoryMax == "256M";
assert service.serviceConfig.CPUQuota == "25%";
assert builtins.all (entry: entry.assertion) enabled.assertions;
pkgs.runCommand "fleet-monitor-configuration" {} ''touch $out''
