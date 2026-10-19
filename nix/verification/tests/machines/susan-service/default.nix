{ pkgs, module, packages }:
let
  relay = import ./relay.nix { inherit pkgs packages; };
in pkgs.testers.runNixOSTest {
  name = "overalls-susan-service";
  nodes.relay = { ... }: { imports = [ module relay.node ]; };
  # @cc [owner:ghuntley,label:verification] susan-service-fixture-scope
  # The packaged Susan release, the real overallsSecrets/SOPS publication path,
  # local PostgreSQL and verify_peer TLS to local fake APNs/OAuth/FCM origins.
  # The fake origins MUST NOT be represented as Apple or Google acceptance.
  testScript = builtins.readFile ./driver.py;
}
