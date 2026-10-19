{ pkgs, module, packages }:
pkgs.testers.runNixOSTest {
  name = "overalls-scim-endpoint";
  defaults = import ../../support/role-node.nix { inherit module packages; };
  nodes.web = { lib, ... }: {
    virtualisation.memorySize = lib.mkForce 4096;
    services.marshall.enable = true;
    services.marshall.publicHost = lib.mkForce "localhost";
  };
  testScript = ''
    start_all()
    web.wait_for_unit("postgresql-setup.service")
    web.succeed("systemctl start overalls-test-migrate.service")
    web.wait_until_succeeds("curl --fail --silent --cacert /run/overalls-test/ca.crt https://localhost:4443/health/ready", timeout=120)
    with subtest("SCIM stays closed until an administrator enables it"):
        web.succeed("curl --silent --show-error --cacert /run/overalls-test/ca.crt --output /tmp/scim.json --write-out '%{http_code}' https://localhost:4443/scim/v2/ServiceProviderConfig | grep -qx 401")
  '';
}
