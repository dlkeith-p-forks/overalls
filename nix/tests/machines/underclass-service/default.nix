# @cc [owner:ghuntley,label:verification] underclass-hegel-stateful
# The service check MUST let Hegel explore restart/reboot/auth-token
# interleavings with invariants checked at join points; request acceptance
# MUST be property-driven over drawn endpoints and tokens.
{ pkgs, module, hegel, ... }:
hegel.runTest {
  name = "overalls-underclass-service";

  properties = {
    enable = true;
    profile = "ci";
    testCases = 10;
    statefulStepCount = 30;
  };

  nodes.machine = { ... }: {
    imports = [ module ];
    services.underclass = {
      enable = true;
      tailscaleServe.enable = false;
      environmentFile = "/etc/underclass-test.env";
    };
    environment.etc."underclass-test.env".text = ''
      UNDERCLASS_PROXY_KEY=synthetic-proxy-key
      UNDERCLASS_UI_TOKEN=synthetic-admin-token
    '';
    environment.systemPackages = [ pkgs.curl pkgs.iproute2 ];
    # Hegel chains restarts deliberately; systemd's default StartIntervalBurst
    # would (correctly) rate-limit the service, which is outside the property
    # under test. Keep start-rate limiting off only inside this check.
    systemd.services.underclass.serviceConfig.StartLimitBurst = 0;
    systemd.services.underclass.unitConfig.StartLimitIntervalSec = 0;
  };

  testScript = ''
    from typing import Any

    from hegel import (
        MachineStateMachine,
        TestCase,
        given,
        invariant,
        one_of,
        rule,
        sampled_from,
        text,
    )

    PROXY_KEY = "synthetic-proxy-key"
    ADMIN_TOKEN = "synthetic-admin-token"

    machine.start()
    machine.wait_for_unit("underclass.service")
    machine.wait_for_open_port(8080)

    with subtest("monitor command is on the host PATH"):
        machine.succeed("command -v underclass")
        machine.succeed("command -v utop")
        machine.succeed("utop --help | grep -q 'watch live pool activity'")

    with subtest("local monitor socket exposes only the read-only snapshot"):
        machine.succeed("test -S /run/underclass/monitor.sock")
        machine.succeed("test $(stat -c %a /run/underclass) = 755")
        machine.succeed("test $(stat -c %a /run/underclass/monitor.sock) = 666")
        machine.succeed(
            "su nobody -s /bin/sh -c 'curl --unix-socket /run/underclass/monitor.sock "
            "-sf http://localhost/monitor | grep -q minute_bins'"
        )
        machine.fail("curl --unix-socket /run/underclass/monitor.sock -sf http://localhost/admin/api/state")
        machine.fail("curl -sf http://127.0.0.1:8080/admin/api/monitor")

    with subtest("service is bounded and unprivileged"):
        machine.succeed("systemctl show underclass.service -p DynamicUser --value | grep -qx yes")
        machine.succeed("systemctl show underclass.service -p MemoryMax --value | grep -qx 1073741824")
        machine.succeed("systemctl show underclass.service -p TasksMax --value | grep -qx 512")
        machine.succeed("systemctl show underclass.service -p NoNewPrivileges --value | grep -qx yes")

    SAFE_TOKEN_ALPHABET = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-"

    @given(
        endpoint=sampled_from(["http://127.0.0.1:8080/v1/models", "http://127.0.0.1:8080/admin/api/state"]),
        credential=one_of(
            sampled_from([PROXY_KEY, ADMIN_TOKEN]),
            text(min_size=1, max_size=24, alphabet=SAFE_TOKEN_ALPHABET).filter(
                lambda value: value not in (PROXY_KEY, ADMIN_TOKEN)
            ),
        ),
    )
    def authorization_matrix(tc: TestCase, endpoint: str, credential: str) -> None:
        admin = endpoint.endswith("/admin/api/state")
        allowed = (credential == ADMIN_TOKEN) if admin else (credential == PROXY_KEY)
        command = f"curl -sf -H 'Authorization: Bearer {credential}' {endpoint}"
        if allowed:
            machine.succeed(command)
        else:
            machine.fail(command)


    class AvailabilityAcrossFaults(MachineStateMachine):
        def setup(self) -> None:
            machine.wait_for_unit("underclass.service")
            machine.wait_for_open_port(8080)

        def _ready(self) -> None:
            machine.wait_for_unit("underclass.service")
            machine.wait_for_open_port(8080)

        @rule(weight=3)
        def query_models_with_proxy_key(self) -> None:
            machine.succeed(
                f"curl -sf -H 'Authorization: Bearer {PROXY_KEY}' "
                "http://127.0.0.1:8080/v1/models | grep -q gpt-5.5"
            )

        @rule(weight=2)
        def query_admin_with_admin_token(self) -> None:
            machine.succeed(
                f"curl -sf -H 'Authorization: Bearer {ADMIN_TOKEN}' "
                "http://127.0.0.1:8080/admin/api/state | grep -q accounts"
            )

        @rule(weight=2)
        def restart_service(self) -> None:
            # Clear any residual failed state so a restart burst never wedges.
            machine.succeed("systemctl reset-failed underclass.service")
            machine.systemctl("restart underclass.service")
            self._ready()

        @rule(weight=1)
        def reboot_node(self) -> None:
            machine.reboot()
            machine.wait_for_shutdown()
            machine.start()
            self._ready()

        @invariant(always=True)
        def listener_stays_loopback(self) -> None:
            machine.succeed("ss -ltn | grep -F '127.0.0.1:8080'")
            machine.fail("ss -ltn | grep -E '0\\.0\\.0\\.0:8080|\\[::\\]:8080'")

        @invariant(always=True)
        def state_persists(self) -> None:
            machine.succeed("test -f /var/lib/underclass/pool.db")

        @invariant(always=True)
        def credentials_never_leak_to_journal(self) -> None:
            machine.fail(f"journalctl -u underclass.service --no-pager | grep -F {PROXY_KEY}")
            machine.fail(f"journalctl -u underclass.service --no-pager | grep -F {ADMIN_TOKEN}")

    AvailabilityAcrossFaults.run()
  '';
}
