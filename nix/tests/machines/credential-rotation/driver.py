"""Three actual Marshall machines: retained encryption and coordinated credential cutover."""

import json
import tempfile
from pathlib import Path
from typing import Protocol


class MachineLike(Protocol):
    name: str

    def succeed(self, *commands: str, timeout: int | None = None) -> str: ...

    def wait_until_succeeds(self, command: str, timeout: int = 900) -> str: ...

    def copy_from_machine(self, source: str, target_dir: str = "") -> None: ...

    def copy_from_host(self, source: str, target: str) -> None: ...


root = "/var/lib/overalls-fleet"
marshalls = [m1, m2, m3]


def probe(machine: MachineLike, **request: str) -> None:
    with tempfile.TemporaryDirectory(prefix="overalls-rotation-request-") as directory:
        source = Path(directory) / "request.json"
        source.write_text(json.dumps(request))
        source.chmod(0o600)
        machine.copy_from_host(str(source), root + "/probe-request.json")
    machine.succeed("systemctl start rotation-probe.service", timeout=120)


def distribute_state(source: MachineLike, name: str) -> None:
    for machine in marshalls:
        if machine != source:
            transfer(source, root + "/" + name + ".json", machine, root + "/" + name + ".json")


def ready(machine: MachineLike) -> None:
    machine.wait_until_succeeds(
        f"curl --fail --silent --cacert {root}/ca.crt https://{machine.name}:4443/health/ready",
        timeout=120,
    )
    machine.succeed("rotation-fixture running " + machine.name)


def check_state(name: str, accepted: bool = True) -> None:
    expected = "accept" if accepted else "reject"
    for machine in marshalls:
        machine.succeed(f"rotation-fixture http {machine.name} {name} {expected}")


def deliver(machine: MachineLike) -> None:
    transfer(db, f"{root}/{machine.name}/marshall.enc.json", machine, root + "/marshall.enc.json")


def restart(machine: MachineLike) -> None:
    machine.succeed(f"systemctl stop marshall-{machine.name}.service")
    machine.succeed("systemctl restart overalls-secrets-marshall.service")
    machine.succeed(f"systemctl start marshall-{machine.name}.service")
    ready(machine)


start_all()
db.wait_for_unit("postgresql-setup.service")
db.succeed(
    f"sudo -u postgres psql --no-psqlrc -d marshall -Atc 'SELECT id FROM overalls_fleet_fixture' | tr -d '\\n' > {root}/fixture-id"
)
for machine in marshalls:
    machine.wait_until_succeeds("test -s /etc/ssh/ssh_host_ed25519_key.pub")
    transfer(machine, "/etc/ssh/ssh_host_ed25519_key.pub", db, f"{root}/{machine.name}.pub")
db.succeed("rotation-fixture seal initial")
db.succeed("rotation-fixture database-passwords initial")
for machine in marshalls:
    for filename in ["tls.key", "tls.crt", "marshall.enc.json"]:
        transfer(db, f"{root}/{machine.name}/{filename}", machine, f"{root}/{filename}")
    for filename in ["ca.crt", "fixture-id"]:
        transfer(db, f"{root}/{filename}", machine, f"{root}/{filename}")
    machine.succeed(f"touch {root}/delivered")
    machine.wait_for_unit("overalls-secrets-marshall.service")
probe(m1, action="migrate")
for machine in marshalls:
    machine.succeed(f"touch {root}/ready")
    ready(machine)

with subtest("shared secrets authenticate old encrypted credentials and logins on every machine"):
    probe(m1, action="create", state="state-old", tag="fleet")
    distribute_state(m1, "state-old")
    check_state("state-old")

with subtest("stage the new decryption key everywhere before any node writes with it"):
    db.succeed("rotation-fixture seal stage")
    for machine in marshalls:
        deliver(machine)
        restart(machine)
        check_state("state-old")

with subtest(
    "new ciphertext works on staged and promoted nodes while old ciphertext remains readable"
):
    db.succeed("rotation-fixture seal promote")
    deliver(m1)
    restart(m1)
    probe(m1, action="create", state="state-new-key", tag="rotation")
    distribute_state(m1, "state-new-key")
    check_state("state-old")
    check_state("state-new-key")
    for machine in [m2, m3]:
        deliver(machine)
        restart(machine)
        check_state("state-old")
        check_state("state-new-key")

with subtest(
    "single signing keys and database credentials change only while all consumers are stopped"
):
    for machine in marshalls:
        machine.succeed(f"systemctl stop marshall-{machine.name}.service")
        machine.fail(f"systemctl is-active --quiet marshall-{machine.name}.service")
    db.succeed("rotation-fixture seal cutover")
    db.succeed(
        f"install -m 0600 -o postgres -g postgres {root}/database-rotate.sql /var/lib/overalls-fleet-db/rotate.sql"
    )
    db.succeed(
        "sudo -u postgres psql --no-psqlrc -v ON_ERROR_STOP=1 -d marshall -f /var/lib/overalls-fleet-db/rotate.sql > /dev/null"
    )
    db.succeed("rotation-fixture database-passwords cutover")
    for machine in marshalls:
        deliver(machine)
        restart(machine)
    check_state("state-old", accepted=False)
    check_state("state-new-key", accepted=False)
    # A cookie signed with the NEW cookie key but containing the OLD stored JWT
    # isolates token-signing rejection from outer-cookie rejection.
    probe(m1, action="resign-cookie", source="state-old", state="state-old-token")
    distribute_state(m1, "state-old-token")
    check_state("state-old-token", accepted=False)
    probe(m1, action="create", state="state-cutover", tag="rotation")
    distribute_state(m1, "state-cutover")
    check_state("state-cutover")

with subtest("retiring a still-needed encryption key is rejected without exposing old data"):
    probe(m1, action="missing-old-key", old="state-old", new="state-new-key")
    for machine in marshalls:
        ready(machine)
    check_state("state-cutover")
