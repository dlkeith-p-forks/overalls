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
  runtime = evaluate {
    services.lilly.protectedAddressFiles = [ "/run/fixture-addresses/primary" "/run/fixture-addresses/service" ];
    services.lilly.protectedAddressUnits = [ "fixture-addresses.service" ];
  };
  runtimeLilly = runtime.systemd.services.lilly;
  runtimeBrady = runtime.systemd.services.brady;
  protected = import ../../../domains/system/protected-addresses.nix {
    inherit (pkgs) lib; files = runtime.services.lilly.protectedAddressFiles;
  };
in
assert valid runtime;
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
# lilly-protected-runtime-addresses: runtime files reach Lilly and Brady only
# as credentials, after their publishing unit, and extend the evaluated list.
assert service.environment.BRADY_CONFIG_FILE != "/run/brady/config.json";
assert !(pkgs.lib.hasInfix "protected_address" ready.systemd.services.lilly.preStart);
assert builtins.elem "protected-address-0:/run/fixture-addresses/primary" runtimeLilly.serviceConfig.LoadCredential;
assert builtins.elem "protected-address-1:/run/fixture-addresses/service" runtimeLilly.serviceConfig.LoadCredential;
assert builtins.elem "fixture-addresses.service" runtimeLilly.requires;
assert builtins.elem "fixture-addresses.service" runtimeLilly.after;
assert pkgs.lib.hasInfix ''--rawfile protected_address_1 "$CREDENTIALS_DIRECTORY/protected-address-1"'' runtimeLilly.preStart;
assert pkgs.lib.hasInfix ".execution.protected_cidrs +=" runtimeLilly.preStart;
assert runtimeBrady.environment.BRADY_CONFIG_FILE == "/run/brady/config.json";
assert builtins.elem "protected-address-0:/run/fixture-addresses/primary" runtimeBrady.serviceConfig.LoadCredential;
assert builtins.elem "fixture-addresses.service" runtimeBrady.requires;
assert pkgs.lib.hasInfix ".protected_cidrs +=" runtimeBrady.preStart;
assert !valid (evaluate { services.lilly.protectedAddressFiles = [ "/run/fixture-addresses/primary" ]; });
assert !valid (evaluate {
  services.lilly.protectedAddressFiles = [ "/run/fixture-addresses/primary" "/run/fixture-addresses/primary" ];
  services.lilly.protectedAddressUnits = [ "fixture-addresses.service" ];
});
pkgs.runCommand "brady-configuration" { nativeBuildInputs = [ pkgs.jq ]; } ''
  export CREDENTIALS_DIRECTORY=$PWD/credentials
  mkdir "$CREDENTIALS_DIRECTORY"
  render() {
    jq ${protected.jqArguments} '${protected.jqFilter ".execution.protected_cidrs"}' \
      <<< '{"execution":{"protected_cidrs":["10.90.0.0/24"]}}'
  }
  printf '192.0.2.10\n' > "$CREDENTIALS_DIRECTORY/protected-address-0"
  printf '198.51.100.7' > "$CREDENTIALS_DIRECTORY/protected-address-1"
  test "$(render | jq -c .execution.protected_cidrs)" = '["10.90.0.0/24","192.0.2.10/32","198.51.100.7/32"]'
  for bad in 192.0.2.010 0.0.0.0 127.0.0.1 224.0.0.1 192.0.2.1/24 "" 'not-an-address'; do
    printf '%s' "$bad" > "$CREDENTIALS_DIRECTORY/protected-address-1"
    if render > /dev/null 2>&1; then echo "accepted malformed runtime address" >&2; exit 1; fi
  done
  rm "$CREDENTIALS_DIRECTORY/protected-address-1"
  if render > /dev/null 2>&1; then echo "accepted a missing runtime address" >&2; exit 1; fi
  touch $out
''
