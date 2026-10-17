{ pkgs, module, packages }:
let
  python = pkgs.python3.withPackages (p: [ p.playwright ]);
  # @cc [owner:ghuntley,label:verification] admin-account-browser-subprocess-typing
  # The executed browser helper MUST pass its own type check against the same
  # packaged Python and Playwright, outside repository discovery exclusions.
  checkedBrowser = pkgs.runCommand "admin-account-browser-typed" {
    nativeBuildInputs = [ pkgs.ty pkgs.nodejs ];
  } ''
    mkdir -p "$out"
    cp ${./browser.py} "$out/browser.py"
    cp ${./browser.js} "$out/browser.js"
    ty check --python ${python}/bin/python3 "$out/browser.py"
    ${pkgs.typescript}/bin/tsc --allowJs --checkJs --noEmit --strict --lib ES2022,DOM "$out/browser.js"
  '';
in (pkgs.testers.runNixOSTest {
  name = "overalls-admin-account-browser";
  defaults = import ../../support/role-node.nix { inherit module packages; };
  nodes.web = { config, lib, ... }: {
    virtualisation.memorySize = lib.mkForce 4096;
    services.marshall.enable = true;
    # Match the deployed Overalls per-replica pool and fleet connection budget.
    # The shared service fixture's two connections are insufficient for browser
    # projections alongside queue=false readiness probes.
    services.marshall.poolSize = lib.mkForce 10;
    services.marshall.databaseConnectionBudget = lib.mkForce 64;
    services.marshall.publicHost = lib.mkForce "localhost";
    services.marshallProxy.enable = true;
    services.marshallProxy.publicHost = lib.mkForce "localhost";
    environment.systemPackages = [ python pkgs.chromium pkgs.nssTools ];
    systemd.services.admin-account-seed = {
      requires = [ "overalls-test-migrate.service" ];
      after = [ "overalls-test-migrate.service" ];
      environment = config.systemd.services.overalls-test-migrate.environment;
      serviceConfig = {
        Type = "oneshot";
        EnvironmentFile = "/run/overalls-test/marshall.env";
      };
      script = ''
        exec ${pkgs.coreutils}/bin/env -u PORT MARSHALL_INSTANCE_ID=admin-account-seed MARSHALL_DB_TLS=verify \
          ${packages.marshall}/bin/marshall eval 'Code.eval_file("${./seed.exs}")'
      '';
    };
  };
  testScript = ''
    start_all()
    web.wait_for_unit("postgresql-setup.service")
    web.succeed("systemctl start overalls-test-migrate.service")
    web.wait_until_succeeds("curl --fail --silent --cacert /run/overalls-test/ca.crt https://localhost/health/ready", timeout=120)
    web.succeed("systemctl start admin-account-seed.service")
    web.succeed("mkdir -p /root/.pki/nssdb; certutil -N --empty-password -d sql:/root/.pki/nssdb")
    web.succeed("certutil -A -d sql:/root/.pki/nssdb -n overalls-fixture -t C,, -i /run/overalls-test/ca.crt")
    with subtest("Inline administrative account reset, cancellation and stale mounted authority"):
        web.succeed("${python}/bin/python ${checkedBrowser}/browser.py", timeout=240)
  '';
}) // { inherit checkedBrowser; }
