{ pkgs, module, ... }:
pkgs.testers.runNixOSTest {
  name = "overalls-independent-fleet-exporter";
  nodes.machine = { ... }: {
    imports = [ module ];
    virtualisation.memorySize = 1024;
    services.overallsFleetExporter = {
      enable = true;
      roles = [];
      units = [ "exporter-workload.service" ];
      zfs = false;
    };
    systemd.services.exporter-workload = {
      wantedBy = [ "multi-user.target" ];
      serviceConfig.ExecStart = "${pkgs.coreutils}/bin/sleep infinity";
    };
    systemd.services.exporter-updater-fixture = {
      wantedBy = [ "multi-user.target" ];
      before = [ "overalls-fleet-exporter.service" ];
      serviceConfig.Type = "oneshot";
      script = ''
        install -d -m 700 /var/lib/overalls-auto-update
        ${pkgs.python3}/bin/python - <<'PY'
        import json
        import time
        from pathlib import Path
        Path("/var/lib/overalls-auto-update/status.json").write_text(json.dumps({
            "phase": "healthy", "updatedAt": int(time.time()), "failures": 0, "failure": None,
        }))
        PY
      '';
    };
    environment.systemPackages = [ pkgs.curl ];
  };
  testScript = ''
    start_all()
    machine.wait_for_unit("exporter-workload.service")
    machine.wait_for_unit("overalls-fleet-exporter.service")
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:9466/metrics | grep '^overalls_fleet_collection_valid 1$'", timeout=30)
    with subtest("real procfs and cgroup measurements need no Marshall or credentials"):
        output = machine.succeed("curl -fsS http://127.0.0.1:9466/metrics")
        assert 'kind="host"' in output
        assert 'entity="exporter-workload.service"' in output
        assert 'kind="updater",entity="updater",field="updater_phase",state="healthy"' in output
        assert "placement_id" not in output and "invocation_id" not in output
        assert "deployment_revision" not in output
        machine.fail("systemctl cat marshall.service")
        machine.fail("test -e /run/overalls-secrets/fleet-monitor/credential.json")
        machine.fail("curl -fsS http://127.0.0.1:9466/unknown")
    with subtest("exporter outage does not stop independently supervised work"):
        before = machine.succeed("systemctl show -p MainPID --value exporter-workload.service")
        machine.succeed("systemctl kill --kill-whom=main --signal=SIGKILL overalls-fleet-exporter.service")
        machine.wait_for_unit("overalls-fleet-exporter.service")
        machine.wait_until_succeeds("curl -fsS http://127.0.0.1:9466/metrics | grep '^overalls_fleet_collection_valid 1$'", timeout=30)
        assert machine.succeed("systemctl show -p MainPID --value exporter-workload.service") == before
    with subtest("malformed updater status becomes unknown without fabricated health"):
        machine.succeed("printf '[]' > /var/lib/overalls-auto-update/status.json")
        machine.wait_until_succeeds("curl -fsS http://127.0.0.1:9466/metrics | grep 'kind=\"updater\",entity=\"updater\",measure=\"status_valid\"} 0'", timeout=30)
  '';
}
