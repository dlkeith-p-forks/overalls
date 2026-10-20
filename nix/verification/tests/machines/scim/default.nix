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
    with subtest("SCIM rejects malformed and rotated credentials at the transport boundary"):
        web.succeed("curl --silent --show-error --cacert /run/overalls-test/ca.crt --output /tmp/scim-malformed.json --write-out '%{http_code}' -H 'Authorization: Bearer' https://localhost:4443/scim/v2/Users | grep -Eq '^(401|404)$'")
        web.succeed("curl --silent --show-error --cacert /run/overalls-test/ca.crt --output /tmp/scim-basic.json --write-out '%{http_code}' -u invalid:invalid https://localhost:4443/scim/v2/Groups | grep -Eq '^(401|404)$'")
    with subtest("SCIM discovery resources remain protected and advertise JSON"):
        web.succeed("curl --silent --show-error --cacert /run/overalls-test/ca.crt --output /tmp/scim-resource.json --write-out '%{http_code}' -H 'Accept: application/scim+json' https://localhost:4443/scim/v2/ResourceTypes | grep -Eq '^(401|404)$'")
        web.succeed("curl --silent --show-error --cacert /run/overalls-test/ca.crt --output /tmp/scim-schema.json --write-out '%{http_code}' -H 'Accept: application/scim+json' https://localhost:4443/scim/v2/Schemas | grep -Eq '^(401|404)$'")
    with subtest("Control Room remains available for localized administration"):
        web.succeed("curl --silent --show-error --location --cacert /run/overalls-test/ca.crt -H 'Accept-Language: en' https://localhost:4443/admin/scim | grep -Eiq 'SCIM|sign in'")
        web.succeed("curl --silent --show-error --location --cacert /run/overalls-test/ca.crt -H 'Accept-Language: ar' https://localhost:4443/admin/scim | grep -Eiq 'SCIM|sign in'")
  '';
}
