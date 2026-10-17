# @cc [owner:ghuntley,label:verification] inception-native-stack-scope
# This fixture MUST boot the source-built Inception image through actual Lilly
# and Firecracker. Console bytes and credential contents MUST remain withheld.
# Driver-only creation MUST NOT establish outer Marshall profile admission.
import json
import os
import shlex
import tempfile
from pathlib import Path


# @cc [owner:ghuntley,label:verification] inception-native-state-capacity
# The native fixture MUST refuse a VM state filesystem with less than 64 GiB
# free before starting machines, so fixture disk exhaustion cannot masquerade
# as an Inception or PostgreSQL runtime failure.
def require_vm_state_space() -> None:
    directory = Path(os.environ.get("XDG_RUNTIME_DIR", tempfile.gettempdir()))
    filesystem = os.statvfs(directory)
    assert filesystem.f_bavail * filesystem.f_frsize >= 64 * 1024**3, (
        "Inception test VM state requires at least 64 GiB free"
    )


# @cc [owner:ghuntley,label:verification;recovery] inception-native-command-deadline
# Fixture probe deadlines MUST escalate to SIGKILL before the test driver's
# outer timeout. A process ignoring SIGTERM MUST NOT hold the result pipe open
# indefinitely. Commands and their existing acceptance assertions remain intact.
def bounded_succeed(*commands: str, timeout: int) -> None:
    try:
        outer.succeed(
            *(
                f"timeout --kill-after=10s {timeout - 15}s bash -c {shlex.quote(command)}"
                for command in commands
            ),
            timeout=timeout,
        )
    except Exception:
        # A timed-out probe's stdout is lost with the command. Report only its
        # last fixed phase label; never replay the journal's arbitrary bytes.
        status, phase = outer.execute(
            "awk '/^[a-z0-9 -]+ at [0-9]+$/ { value=$0 } "
            'END { if (value == "") exit 1; print value }\' '
            "/run/inception-test/probe-steps.log"
        )
        print(f"inception probe last phase (status {status}): {phase}")
        raise


require_vm_state_space()
internet.start()
internet.wait_for_unit("public-fixture.service")
internet.wait_for_unit("inception-fixture-issuer.service")
internet.wait_for_unit("inception-provider-fixture.service")
internet.wait_until_succeeds(
    "curl --fail --silent --cacert /var/lib/inception-fixture-issuer/ca.crt https://localhost:9444/roots/0 > /var/lib/inception-fixture-issuer/root.pem"
)
outer.start()
# Schema migration remains an explicit driver action.
outer.wait_for_unit("postgresql.service")
transfer(
    internet,
    "/var/lib/inception-fixture-issuer/ca.crt",
    outer,
    "/run/inception-public-issuer-ca.pem",
)
transfer(
    internet, "/var/lib/inception-fixture-issuer/root.pem", outer, "/run/inception-public-roots.pem"
)
outer.succeed(
    "python3 -c "
    + shlex.quote("""
import json, os
from pathlib import Path
os.umask(0o077)
value = json.loads(Path('/etc/inception-public-settings.json').read_bytes())
value['issuer_ca_pem'] = Path('/run/inception-public-issuer-ca.pem').read_text()
value['trust_pem'] = Path('/run/inception-public-roots.pem').read_text()
Path('/run/inception-public-settings.json').write_text(json.dumps(value))
""")
)
outer.succeed("systemctl start overalls-test-migrate.service")
outer.wait_for_unit("multi-user.target")
outer.succeed("test -c /dev/kvm", "systemctl is-active lilly.slice")
outer.succeed(
    "systemctl is-active lilly-inception-preflight.service",
    "test -s /run/lilly-inception/proof.json",
)
outer.succeed("zpool create -O compression=lz4 -O mountpoint=/tank tank /dev/vdb")
outer.succeed("zfs create -o mountpoint=/pool -o quota=800G tank/lilly")
outer.succeed("zfs create -o mountpoint=/direct-pool -o quota=400G tank/direct-lilly")

with subtest("eligibility requires the current boot image probe and Firecracker receipt"):
    bounded_succeed("inception-probe reject-proof", timeout=600)

with subtest("an ordinary user creates Inception through real outer Marshall and Lilly"):
    outer.wait_for_unit("marshall-outer.service")
    bounded_succeed(
        "inception-probe outer-request",
        "systemctl start inception-outer@enroll.service",
        timeout=600,
    )
    outer.succeed("systemctl start inception-outer@enroll-dns.service")
    for machine, address in [(ns1, "11.0.0.3"), (ns2, "11.0.0.4")]:
        machine.start()
        machine.succeed("install -d -m 0700 /run/inception-dns")
        transfer(
            outer,
            "/run/inception-outer/" + machine.name + ".token",
            machine,
            "/run/inception-dns/dns.token",
        )
        transfer(outer, "/run/overalls-test/ca.crt", machine, "/run/inception-dns/control-ca.pem")
        machine.succeed("chmod 0600 /run/inception-dns/*; systemctl start audi-dns.service")
        machine.wait_for_open_port(53, addr=address)
        machine.wait_until_succeeds(
            "python3 /etc/public-dns-probe.py /etc/public-dns-probe.json " + address
        )
        machine.wait_until_succeeds(
            "python3 -c "
            + shlex.quote("""
import json, socket
with socket.socket(socket.AF_UNIX) as peer:
    peer.settimeout(2)
    peer.connect('/run/audi-dns/status.sock')
    with peer.makefile('rb') as stream:
        value = json.loads(stream.readline(4097))
    assert value == {'version': 1, 'role': 'dns', 'ready': True}
""")
        )
    outer.succeed(
        'install -d -m 0700 /run/inception-test; umask 077; printf \'%s\' \'{"version":1,"host":"smtp.example.test","port":587,"username":"fixture","password":"outer-synthetic","from":"dev@example.test","tls":"starttls"}\' > /run/inception-test/smtp.json'
    )
    outer.succeed("systemctl start inception-outer-lilly.service")
    outer.succeed("systemctl start inception-outer@enroll-gateway.service")
    outer.succeed("systemctl start audi.service")
    outer.wait_for_open_port(22, addr="11.0.0.5")
    outer.wait_for_open_port(443, addr="11.0.0.5")
    outer.wait_until_succeeds("systemctl start inception-outer@enable.service", timeout=180)
    # The cache-only rebuild can consume much of the nested VM's boot window.
    # Sample near the image build bound while retaining margin before Lilly's forty-minute
    # production readiness deadline stops an unsuccessful guest.
    outer.succeed(
        "systemd-run --unit=inception-core-diagnostics --on-active=28min "
        "--property=TimeoutStartSec=180 "
        "/run/current-system/sw/bin/inception-probe diagnose-core 1 1"
    )
    try:
        outer.succeed("systemctl start inception-outer@create.service", timeout=2700)
    except Exception:
        # The diagnostic command emits only the fixed predicates documented in
        # probe.exs. Replay those bounded results at the assertion site; the
        # complete guest journal and terminal bytes remain withheld.
        status, diagnostics = outer.execute(
            "journalctl -u inception-core-diagnostics.service --no-pager -o cat"
        )
        print(f"inception core diagnostics (status {status}):\n{diagnostics}")
        raise
    bounded_succeed("inception-probe verify 1 1", timeout=900)
    outer.succeed("systemctl start inception-outer@create-two.service", timeout=2700)
    bounded_succeed("inception-probe verify 1 1 2", timeout=900)

with subtest("inner control obtains a real DNS-01 certificate through both parent replicas"):
    first = json.loads(outer.succeed("cat /run/inception-outer/origins.json"))
    second = json.loads(outer.succeed("cat /run/inception-outer/two-origins.json"))
    assert first["namespace"] != second["namespace"]
    try:
        for origins in [first, second]:
            control_hostname = origins["control"]
            assert all(
                part and all(c in "abcdefghijklmnopqrstuvwxyz0123456789-" for c in part)
                for part in control_hostname.split(".")
            )
            for server in ["11.0.0.3", "11.0.0.4"]:
                for transport in ["", "+tcp"]:
                    command = (
                        "dig @"
                        + server
                        + " "
                        + shlex.quote(control_hostname)
                        + " A +short "
                        + transport
                    )
                    internet.wait_until_succeeds(
                        'test "$(' + command + ')" = 11.0.0.5', timeout=240
                    )
            internet.wait_until_succeeds(
                "curl --fail --silent --show-error --max-time 5 --cacert /var/lib/inception-fixture-issuer/root.pem "
                + "--resolve "
                + shlex.quote(control_hostname + ":443:11.0.0.5")
                + " "
                + shlex.quote("https://" + control_hostname + "/health/ready")
                + " >/dev/null",
                timeout=240,
            )
    except Exception:
        for instance in [1, 2]:
            try:
                bounded_succeed(f"inception-probe diagnose-public 1 1 {instance}", timeout=300)
            except Exception:
                print(f"Public diagnostics unavailable for fixture instance {instance}")
        raise

with subtest("neither inner public listener accepts fleet APIs or forwarding-header bypasses"):
    for origins in [first, second]:
        internet.succeed(
            "python3 /etc/inception-public-boundary.py "
            + shlex.quote(origins["control"])
            + " 11.0.0.5 /var/lib/inception-fixture-issuer/root.pem",
            timeout=120,
        )

with subtest("two public browsers authenticate independently and establish inner WebSockets"):
    internet.succeed("install -d -m 0700 /run/inception-browser")
    for instance, filename in [(1, "first"), (2, "second")]:
        bounded_succeed(f"inception-probe browser-token 1 1 {instance}", timeout=300)
        transfer(
            outer,
            f"/run/inception-test/browser-{instance}.json",
            internet,
            f"/run/inception-browser/{filename}.json",
        )
    internet.succeed(
        "python3 /etc/inception-browser.py "
        + shlex.quote(first["control"])
        + " "
        + shlex.quote(second["control"]),
        timeout=180,
    )

with subtest("each environment starts private services with independent provider credentials"):
    for instance in [1, 2]:
        bounded_succeed(f"inception-probe private-services 1 1 {instance}", timeout=900)

with subtest("both independent inner control planes manage real nested guests"):
    for instance in [1, 2]:
        bounded_succeed(f"inception-probe inner-create 1 1 {instance}", timeout=900)
    for instance in [1, 2]:
        bounded_succeed(f"inception-probe wildcard 1 1 {instance}", timeout=660)
    for action, limit in [("stop", 600), ("start", 900), ("delete", 600)]:
        for instance in [1, 2]:
            bounded_succeed(f"inception-probe inner-{action} 1 1 {instance}", timeout=limit)

with subtest("deleting one environment preserves its sibling before paired cleanup"):
    outer.succeed("systemctl start inception-outer@delete.service", timeout=240)
    bounded_succeed("inception-probe deleted 1 1", timeout=600)
    bounded_succeed("inception-probe verify 1 1 2", timeout=900)
    outer.succeed("systemctl start inception-outer@delete-two.service", timeout=240)
    bounded_succeed("inception-probe deleted 1 1 2", timeout=600)
    outer.succeed("systemctl stop inception-outer-lilly.service")
    bounded_succeed("inception-probe network-restore", timeout=600)

with subtest("Inception boots an enrolled PostgreSQL Marshall Lilly stack"):
    bounded_succeed("inception-probe start", timeout=2700)
    bounded_succeed("inception-probe verify", timeout=900)
    bounded_succeed("inception-probe storage-refusal", timeout=600)

with subtest("restart preserves storage identity credentials and developer edits"):
    bounded_succeed("inception-probe remember", "inception-probe rotate", timeout=600)
    bounded_succeed("inception-probe stop 2", timeout=600)
    bounded_succeed("inception-probe start 3", timeout=2700)
    bounded_succeed("inception-probe retained 3", timeout=600)

with subtest("deletion reclaims both owned disks"):
    bounded_succeed("inception-probe delete 4", timeout=600)
    outer.fail("test -e /direct-pool/vms/dddddddd-dddd-4ddd-8ddd-000000000140/rootfs.ext4")
    outer.fail("test -e /direct-pool/vms/dddddddd-dddd-4ddd-8ddd-000000000140/data.raw")
