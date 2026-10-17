{ pkgs, module }:
let
  evaluate = extra: (import (pkgs.path + "/nixos/lib/eval-config.nix") {
    inherit pkgs;
    system = pkgs.stdenv.hostPlatform.system;
    modules = [ module {
      system.stateVersion = "26.05";
      boot.loader.grub.enable = false;
      fileSystems."/" = { device = "/dev/vda"; fsType = "ext4"; };
      networking.hostId = "12345678";
      services.lilly = {
        enable = true;
        hostId = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa";
        controlPlane = "https://control.example.test";
        egressInterface = "eth0";
        pools = [{
          id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb";
          path = "/var/lib/lilly-pool";
          filesystem_id = "zfs:123:456";
          storage = { dataset = "tank/lilly"; dataset_guid = "456"; zpool_guid = "123"; };
        }];
      };
      services.brady = {
        enable = true;
        issuerCertificateFile = "/run/test-credentials/ca.pem";
        issuerKeyFile = "/run/test-credentials/ca.key";
      };
      services.overallsFleetExporter.enable = true;
    } extra ];
  }).config;
  ready = evaluate {};
  valid = c: builtins.all (entry: entry.assertion) c.assertions;
  service = ready.systemd.services.brady;
in
assert valid ready;
assert !valid (evaluate { services.brady.httpsPorts = [ 80 ]; });
assert !valid (evaluate { services.brady.poolId = "cccccccc-cccc-4ccc-8ccc-cccccccccccc"; });
assert service.serviceConfig.User == "brady";
assert builtins.elem "d /run/lilly-brady 2750 lilly brady - -" ready.systemd.tmpfiles.rules;
assert ready.systemd.services.brady-pressure.serviceConfig.Group == "brady";
assert ready.systemd.services.brady-pressure.serviceConfig.RuntimeDirectoryMode == "0750";
assert ready.systemd.services.brady-pressure.serviceConfig.ReadWritePaths == [ "/var/cache/brady" "/var/lib/lilly-pool" ];
assert service.serviceConfig.CapabilityBoundingSet == [ "CAP_NET_RAW" ];
assert service.serviceConfig.NetworkNamespacePath == "/run/netns/lilly-${builtins.substring 0 12 (builtins.hashString "sha256" ready.services.lilly.hostId)}";
assert service.environment.BRADY_FLEET_MONITOR == "1";
assert builtins.elem "brady" ready.services.overallsFleetExporter.roles;
assert builtins.elem "brady.service" ready.services.overallsFleetExporter.units;
assert !(builtins.elem "brady-storage.service" service.requires);
assert !(builtins.elem "lilly.service" service.requires);
assert pkgs.lib.hasInfix ".execution.brady.uid = $brady_uid" ready.systemd.services.lilly.preStart;
pkgs.runCommand "brady-configuration" {} ''touch $out''
