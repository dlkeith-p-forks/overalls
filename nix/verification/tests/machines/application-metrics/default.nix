{ pkgs, module, packages }:
pkgs.testers.runNixOSTest {
  name = "overalls-application-metrics";
  defaults = { ... }: {
    imports = [ (import ../../support/role-node.nix { inherit module packages; }) ];
    services.overallsLogging = {
      enable = true;
      environment = "fixture";
      outputs.fixture = {
        type = "native";
        plugin = "stdout";
        sources = [ "marshall" "lilly" "metrics" ];
        queueBytes = 8388608;
      };
    };
  };
  nodes = {
    control = { services.marshall.enable = true; };
    host = { services.lilly.enable = true; };
  };
  # @cc [owner:ghuntley,label:verification] actual-application-metric-delivery
  # Both source-built applications MUST emit their own periodic summaries through
  # journald and the real collector. Injected summaries cannot satisfy this check.
  # No guest execution, replicated control plane or live AWS claim follows.
  testScript = ''
    start_all()
    control.wait_for_unit("postgresql-setup.service")
    control.succeed("systemctl start overalls-test-migrate.service")
    control.wait_for_unit("marshall-control.service")
    control.wait_until_succeeds("curl --fail --silent --cacert /run/overalls-test/ca.crt https://localhost:4443/health/ready", timeout=120)
    host.wait_for_unit("lilly.service")
    for machine, service in [(control, "marshall"), (host, "lilly")]:
        machine.wait_for_unit("overalls-logging.service")
        machine.wait_until_succeeds(
            f"journalctl -u overalls-logging.service --no-pager | grep 'overalls_gauge_beam_processes.*service=\"{service}\".* = [1-9]'",
            timeout=180,
        )
  '';
}
