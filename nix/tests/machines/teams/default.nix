{ pkgs, module, packages }:
let
  python = pkgs.python3.withPackages (p: [ p.playwright ]);
  # @cc [owner:ghuntley,label:verification] teams-browser-subprocess-typing
  # The executed browser helper MUST pass its own type check against the same
  # packaged Python and Playwright, outside repository discovery exclusions.
  checkedBrowser = pkgs.runCommand "teams-browser-typed" {
    nativeBuildInputs = [ pkgs.ty ];
  } ''
    mkdir -p "$out"
    cp ${./browser.py} "$out/browser.py"
    ty check --python ${python}/bin/python3 "$out/browser.py"
  '';
in (pkgs.testers.runNixOSTest {
  name = "overalls-teams-browser";
  defaults = import ../../support/role-node.nix { inherit module packages; };
  nodes.web = { config, lib, ... }: {
    virtualisation.memorySize = lib.mkForce 4096;
    services.marshall.enable = true;
    services.marshall.publicHost = lib.mkForce "localhost";
    environment.systemPackages = [ python pkgs.chromium pkgs.nssTools ];
    systemd.services.teams-seed = {
      requires = [ "overalls-test-migrate.service" ];
      after = [ "overalls-test-migrate.service" ];
      environment = config.systemd.services.overalls-test-migrate.environment;
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = "/run/overalls-test/marshall.env";
      };
      script = ''
        exec ${pkgs.coreutils}/bin/env -u PORT MARSHALL_INSTANCE_ID=teams-seed MARSHALL_DB_TLS=verify \
          ${packages.marshall}/bin/marshall eval 'Code.eval_file("${./seed.exs}")'
      '';
    };
  };
  # @cc [owner:ghuntley,label:verification] teams-browser-native-authority
  # Three ordinary accounts MUST change team authority through the source-built
  # release over verified HTTPS. Still-connected pages MUST fail to retain owner
  # or member authority after committed transfer/removal. Persisted ordinary-user
  # flags MUST be checked after login and after the journey. Database observation
  # MUST confirm one owner; fixture seeds MUST NOT perform team mutations.
  # Creation collisions MUST refuse without claiming another account's team;
  # retries MUST leave one creation receipt and fresh names MUST acquire an owner.
  testScript = ''
    start_all()
    web.wait_for_unit("postgresql-setup.service")
    web.succeed("systemctl start overalls-test-migrate.service")
    web.wait_until_succeeds("curl --fail --silent --cacert /run/overalls-test/ca.crt https://localhost:4443/health/ready", timeout=120)
    web.succeed("systemctl start teams-seed.service")
    web.succeed("mkdir -p /root/.pki/nssdb; certutil -N --empty-password -d sql:/root/.pki/nssdb")
    web.succeed("certutil -A -d sql:/root/.pki/nssdb -n overalls-fixture -t C,, -i /run/overalls-test/ca.crt")
    with subtest("ownership consent and membership revocation reject stale browser authority"):
        web.succeed("${python}/bin/python ${checkedBrowser}/browser.py", timeout=180)
        web.copy_from_vm("/tmp/teams-authority.png")
        web.copy_from_vm("/tmp/teams-creation.png")
        owners = web.succeed("su -s /bin/sh postgres -c \"psql -d marshall -Atc \\\"SELECT count(*) FROM team_members m JOIN teams t ON t.id = m.team_id WHERE t.name = 'native-authority' AND m.archived_at IS NULL AND m.role = 'owner'\\\"\"").strip()
        assert owners == "1", owners
        creations = web.succeed("su -s /bin/sh postgres -c \"psql -d marshall -Atc \\\"SELECT t.name, count(e.id) FROM teams t JOIN account_admin_events e ON e.target_id = t.id WHERE e.kind = 'team_create' GROUP BY t.name ORDER BY t.name\\\"\"").strip()
        assert creations == "native-authority|1\nnative-created-after-collision|1", creations
        fresh_owner = web.succeed("su -s /bin/sh postgres -c \"psql -d marshall -Atc \\\"SELECT u.email FROM teams t JOIN team_members m ON m.team_id = t.id JOIN users u ON u.id = m.user_id WHERE t.name = 'native-created-after-collision' AND m.role = 'owner' AND m.archived_at IS NULL\\\"\"").strip()
        assert fresh_owner == "team-owner@example.test", fresh_owner
  '';
}) // { inherit checkedBrowser; }
