{ pkgs, module, packages }:
let
  # Read-only durable-state probes and the enabling fixture run inside the
  # packaged release against the VM database, as the other machine fixtures do.
  releaseEval = file: ''
    exec ${pkgs.coreutils}/bin/env -u PORT MARSHALL_DB_TLS=verify \
      ${packages.marshall}/bin/marshall eval 'Code.eval_file("${file}")'
  '';
in
pkgs.testers.runNixOSTest {
  name = "overalls-scim-endpoint";
  defaults = import ../../support/role-node.nix { inherit module packages; };
  nodes.web = { config, lib, ... }: {
    virtualisation.memorySize = lib.mkForce 4096;
    services.marshall.enable = true;
    services.marshall.publicHost = lib.mkForce "localhost";
    environment.systemPackages = [ pkgs.jq ];
    systemd.services.scim-seed = {
      requires = [ "overalls-test-migrate.service" ];
      after = [ "overalls-test-migrate.service" ];
      environment = config.systemd.services.overalls-test-migrate.environment // {
        MARSHALL_INSTANCE_ID = "scim-seed";
      };
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = "/run/overalls-test/marshall.env";
        UMask = "0077";
      };
      script = releaseEval ./seed.exs;
    };
    systemd.services."scim-probe@" = {
      environment = config.systemd.services.overalls-test-migrate.environment // {
        MARSHALL_INSTANCE_ID = "scim-probe";
        SCIM_PROBE = "%i";
      };
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = "/run/overalls-test/marshall.env";
      };
      script = releaseEval ./probe.exs;
    };
  };
  # @cc [owner:ghuntley,label:security;verification] scim-machine-end-to-end
  # The machine test MUST exercise the deployed /scim/v2 endpoint over TLS with
  # the real bearer token, durable Users/Groups writes and the retirement
  # lifecycle; it MUST NOT print the bearer token.
  testScript = ''
    import json

    CURL = "curl --silent --show-error --cacert /run/overalls-test/ca.crt"
    BASE = "https://localhost:4443"
    BEARER = "-H \"Authorization: Bearer $(cat /run/overalls-test/scim-token)\""


    def status(args: str) -> str:
        return web.succeed(f"{CURL} --output /tmp/scim-out.json --write-out '%{{http_code}}' {args}").strip()


    def scim(method: str, path: str, expect: str, body: object | None = None) -> dict:
        data = ""
        if body is not None:
            web.succeed(f"cat > /tmp/scim-body.json <<'JSON'\n{json.dumps(body)}\nJSON")
            data = "--data-binary @/tmp/scim-body.json"
        code = status(f"-X {method} {BEARER} -H 'Content-Type: application/scim+json' {data} {BASE}/scim/v2{path}")
        assert code == expect, f"{method} {path}: expected {expect}, got {code}"
        raw = web.succeed("cat /tmp/scim-out.json")
        return json.loads(raw) if raw.strip() else {}


    def probe(check: str) -> None:
        web.succeed(f"systemctl start scim-probe@{check}.service")


    start_all()
    web.wait_for_unit("postgresql-setup.service")
    web.succeed("systemctl start overalls-test-migrate.service")
    web.wait_until_succeeds(f"{CURL} --fail {BASE}/health/ready", timeout=120)

    with subtest("SCIM stays closed until an administrator enables it"):
        for path in ["ServiceProviderConfig", "Users", "Groups", "ResourceTypes", "Schemas"]:
            code = status(f"-H 'Accept: application/scim+json' {BASE}/scim/v2/{path}")
            assert code == "401", f"{path}: expected 401, got {code}"
        code = status(f"-H 'Authorization: Bearer' {BASE}/scim/v2/Users")
        assert code == "401", f"empty bearer: got {code}"
        code = status(f"-u invalid:invalid {BASE}/scim/v2/Groups")
        assert code == "401", f"basic credentials: got {code}"

    with subtest("Control Room redirects anonymous administrators to localized sign-in"):
        page = web.succeed(f"{CURL} -H 'Accept-Language: en' {BASE}/sign-in")
        assert 'id="user-magic-link-request-magic-link"' in page, "magic-link form missing before SCIM"
        out = web.succeed(f"{CURL} --output /dev/null --write-out '%{{http_code}} %{{redirect_url}}' {BASE}/admin/scim").strip()
        assert out.startswith("302 ") and out.endswith("/sign-in"), f"admin redirect: {out}"
        page = web.succeed(f"{CURL} -H 'Accept-Language: ar' {BASE}/sign-in")
        assert 'dir="rtl"' in page, "Arabic sign-in page is not right-to-left"

    web.succeed("systemctl start scim-seed.service")

    with subtest("Enabling SCIM retires native teams and replaces magic-link sign-in"):
        probe("native-retiring")
        page = web.succeed(f"{CURL} -H 'Accept-Language: en' {BASE}/sign-in")
        assert 'id="scim-sign-in"' in page, "SCIM sign-in panel missing"
        assert 'id="user-magic-link-request-magic-link"' not in page, "magic-link form still rendered while SCIM is enabled"

    with subtest("Only the current bearer token authenticates"):
        code = status(f"-H 'Authorization: Bearer scim_wrong' {BASE}/scim/v2/Users")
        assert code == "401", f"wrong bearer: got {code}"
        config = scim("GET", "/ServiceProviderConfig", "200")
        assert "patch" in config, "ServiceProviderConfig lacks patch support"

    with subtest("Directory users and groups provision Marshall accounts and SCIM-managed teams"):
        alice = scim("POST", "/Users", "201", {
            "schemas": ["urn:ietf:params:scim:schemas:core:2.0:User"],
            "userName": "alice@example.test",
            "externalId": "ext-alice",
            "active": True,
            "emails": [{"value": "alice@example.test", "primary": True}],
        })
        group = scim("POST", "/Groups", "201", {
            "schemas": ["urn:ietf:params:scim:schemas:core:2.0:Group"],
            "displayName": "engineering",
            "externalId": "ext-engineering",
            "members": [{"value": alice["id"]}],
        })
        fetched = scim("GET", f"/Groups/{group['id']}", "200")
        assert [m["value"] for m in fetched.get("members", [])] == [alice["id"]], fetched
        probe("group-synced")

    with subtest("Deactivation starts the seven-day retirement and deletion hides the account"):
        scim("PATCH", f"/Users/{alice['id']}", "200", {
            "schemas": ["urn:ietf:params:scim:api:messages:2.0:PatchOp"],
            "Operations": [{"op": "replace", "path": "active", "value": False}],
        })
        probe("user-retiring")
        scim("DELETE", f"/Users/{alice['id']}", "204")
        scim("GET", f"/Users/{alice['id']}", "404")
        probe("user-retiring")
  '';
}
