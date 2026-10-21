"""Boot actual service roles; Firecracker execution has a separate required suite."""

import json
from collections.abc import Iterable
from typing import Protocol

combined_names = ["combined", "combined-two", "combined-three"]


class MachineLike(Protocol):
    name: str

    def succeed(self, *commands: str, timeout: int | None = None) -> str: ...


def marshall_pids(machine: MachineLike, names: Iterable[str]) -> dict[str, str]:
    return {
        name: machine.succeed(f"systemctl show -p MainPID --value marshall-{name}.service").strip()
        for name in names
    }


# @cc [owner:ghuntley,label:verification;security] release-cookie-complete-private-check
# The role fixture MUST require a 64-character uppercase hex release
# cookie while consuming the complete proc environment under pipefail. Cookie
# bytes MUST NOT be returned to the driver or exposed in test output.
def require_release_cookie(machine: MachineLike, pid: str) -> None:
    if not pid.isdecimal() or int(pid) <= 0:
        raise AssertionError("invalid service process identity")
    machine.succeed(
        f"tr '\\0' '\\n' </proc/{pid}/environ "
        "| grep -E '^RELEASE_COOKIE=[0-9A-F]{64}$' >/dev/null"
    )


start_all()

with subtest("disabled roles create no daemon units"):
    neither.wait_for_unit("multi-user.target")
    neither.fail("systemctl cat lilly.service")
    neither.fail("systemctl cat marshall-neither.service")

with subtest("serving modules do not migrate at boot"):
    for machine in [marshall, combined]:
        machine.wait_for_unit("postgresql-setup.service")
        assert (
            machine.succeed(
                "sudo -u postgres psql -d marshall -Atc "
                "\"SELECT count(*) FROM pg_tables WHERE schemaname='public'\""
            ).strip()
            == "0"
        )
        machine.succeed("systemctl start overalls-test-migrate.service")

with subtest("real releases serve TLS with distinct enforced identities"):
    for machine in [marshall, combined]:
        endpoints = [(machine.name, 4443)]
        if machine == combined:
            endpoints += [("combined-two", 4444), ("combined-three", 4445)]
        for name, port in endpoints:
            unit = f"marshall-{name}.service"
            machine.wait_for_unit(unit)
            machine.wait_until_succeeds(
                "curl --fail --silent --cacert /run/overalls-test/ca.crt "
                f"https://localhost:{port}/health/ready",
                timeout=120,
            )
            uid = machine.succeed(
                f"stat -c %u /proc/$(systemctl show -p MainPID --value {unit})"
            ).strip()
            assert uid != "0"
            release_pid = machine.succeed(f"systemctl show -p MainPID --value {unit}").strip()
            require_release_cookie(machine, release_pid)
            machine.succeed(f"test $(systemctl show -p Slice --value {unit}) = marshall.slice")
            assert (
                machine.succeed(
                    "sudo -u postgres psql -d marshall -Atc "
                    f"\"SELECT count(*) > 0 FROM pg_stat_activity WHERE application_name='marshall:{name}'\""
                ).strip()
                == "t"
            )
            machine.fail(
                f"setpriv --reuid={uid} --regid={uid} --clear-groups cat /run/overalls-test/tls.key"
            )
        machine.fail("curl --fail --silent http://localhost:4999/health/ready")
        machine.fail("curl --fail --silent https://localhost:4443/health/ready")
    combined.succeed("test $(cat /sys/fs/cgroup/marshall.slice/memory.max) -eq 2415919104")
    combined.succeed("test $(systemctl show -p CPUQuotaPerSecUSec --value marshall.slice) = 2s")

combined_before_lilly_restart = marshall_pids(combined, combined_names)
assert "0" not in combined_before_lilly_restart.values()
assert len(set(combined_before_lilly_restart.values())) == 3

# @cc [owner:ghuntley,label:verification;recovery] service-roles-lilly-ownership-proof
# The role check MUST require Lilly's real persistent owner and control identity.
# A terminally failed service MUST stop the wait early without satisfying either proof.
# The live BEAM MUST have the nonroot service UID and no effective capabilities;
# hostd MUST retain root identity and credentials MUST use systemd delivery.
with subtest("Lilly runs unprivileged with a root host-effects service outside the guest slice"):
    for machine in [lilly, combined]:
        machine.wait_for_unit("lilly.service")
        for path in ["/var/lib/lilly/owner.json", "/var/lib/lilly/control/identity.json"]:
            machine.wait_until_succeeds(
                f"test -e {path} || systemctl is-failed --quiet lilly.service",
                timeout=180,
            )
            machine.succeed(f"test -e {path}")
        links = json.loads(machine.succeed("ip -j addr show dev lu303617b97302"))
        assert [(address["local"], address["prefixlen"]) for address in links[0]["addr_info"]] == [
            ("169.254.255.1", 30)
        ]
        machine.succeed("test $(systemctl show -p User --value lilly.service) = lilly")
        machine.wait_for_unit("lilly-hostd.service")
        machine.succeed("test $(systemctl show -p Slice --value lilly.service) = system.slice")
        machine.succeed("test $(cat /sys/fs/cgroup/lilly.slice/memory.max) -eq 268435456")
        machine.succeed("test $(stat -c %a /run/lilly-release/config.json) = 600")
        config = json.loads(machine.succeed("cat /run/lilly-release/config.json"))
        assert config["version"] == 4
        assert config["credential_file"] == "/run/credentials/lilly.service/credential"
        machine.succeed(
            "cmp /run/overalls-test/lilly.json /run/credentials/lilly.service/credential"
        )
        assert "credential" not in config
        pid = machine.succeed("systemctl show -p MainPID --value lilly.service").strip()
        require_release_cookie(machine, pid)
        service_uid = int(machine.succeed("id -u lilly").strip())
        assert service_uid > 0
        for service_pid, expected_uid in [
            (pid, service_uid),
            (machine.succeed("systemctl show -p MainPID --value lilly-hostd.service").strip(), 0),
        ]:
            assert service_pid.isdecimal() and int(service_pid) > 0
            actual_uids = machine.succeed(
                f"awk '$1 == \"Uid:\" {{print $2, $3, $4, $5}}' /proc/{service_pid}/status"
            ).split()
            assert [int(value) for value in actual_uids] == [expected_uid] * 4
        assert (
            int(
                machine.succeed(f"awk '$1 == \"CapEff:\" {{print $2}}' /proc/{pid}/status").strip(),
                16,
            )
            == 0
        )
        machine.succeed(f"test $(readlink /proc/{pid}/ns/mnt) = $(readlink /proc/1/ns/mnt)")
        machine.succeed("systemctl restart lilly.service")
        machine.wait_for_unit("lilly.service")
    assert marshall_pids(combined, combined_names) == combined_before_lilly_restart

with subtest("mandatory private roles decrypt runtime fixture credentials"):
    for machine in [lilly, combined]:
        for service in ["ziggy", "galileo"]:
            machine.wait_for_unit(f"overalls-secrets-{service}.service")
            machine.wait_for_unit(f"{service}.service")
            machine.succeed(f"test -s /run/overalls-secrets/{service}/control.token")
            machine.succeed(f"test -S /run/{service}/proxy.sock")
            machine.succeed(f"test $(stat -c %a /run/overalls-test/{service}.enc.json) = 600")

with subtest("roles remain independent"):
    marshall.fail("systemctl cat lilly.service")
    lilly.fail("systemctl cat marshall-lilly.service")

proxy_request = (
    "curl --silent --cacert /run/overalls-test/ca.crt "
    "--resolve control.example.test:443:127.0.0.1 "
    "https://control.example.test/health/ready"
)

with subtest("proxy terminates TLS and routes only to ready TLS backends"):
    combined.wait_for_unit("haproxy.service")
    combined.wait_until_succeeds(proxy_request + " --fail", timeout=30)
    lilly_pid = combined.succeed("systemctl show -p MainPID --value lilly.service").strip()
    assert lilly_pid != "0"
    combined.succeed("systemctl stop marshall-combined.service")
    combined.wait_until_succeeds(proxy_request + " --fail", timeout=30)
    combined.succeed("systemctl stop marshall-combined-two.service")
    # The last backend must carry readiness independently, rather than all
    # requests accidentally reaching the original one-instance role fixture.
    combined.wait_until_succeeds(proxy_request + " --fail", timeout=30)
    combined.succeed("systemctl stop marshall-combined-three.service")
    combined.wait_until_succeeds(
        "test $(" + proxy_request + " -o /dev/null -w '%{http_code}') = 503",
        timeout=30,
    )
    for name in combined_names:
        combined.succeed(f"systemctl start marshall-{name}.service")
    assert combined.succeed("systemctl show -p MainPID --value lilly.service").strip() == lilly_pid
    combined.wait_until_succeeds(proxy_request + " --fail", timeout=60)

with subtest("proxy rejects wrong backend certificate hostname"):
    combined.succeed("cp /etc/haproxy.cfg /run/proxy-original.cfg")
    # HAProxy 3.3 verifies the SNI name when present; verifyhost is the fallback.
    # Change the module's one logical serverName across all three directives.
    combined.succeed(
        "sed 's/localhost/incorrect.example.test/g' "
        "/run/proxy-original.cfg > /run/proxy-invalid.cfg"
    )
    combined.succeed("cp --remove-destination /run/proxy-invalid.cfg /etc/haproxy.cfg")
    combined.succeed("systemctl restart haproxy.service")
    combined.wait_until_succeeds(
        "test $(" + proxy_request + " -o /dev/null -w '%{http_code}') = 503",
        timeout=30,
    )
    combined.succeed("cp /run/proxy-original.cfg /etc/haproxy.cfg")
    combined.succeed("systemctl restart haproxy.service")
    combined.wait_until_succeeds(proxy_request + " --fail", timeout=30)

with subtest("proxy logs exclude request secrets"):
    combined.succeed(proxy_request + "'?token=synthetic-url-secret' --fail")
    combined.fail("journalctl -u haproxy.service --no-pager | grep -F synthetic-url-secret")
