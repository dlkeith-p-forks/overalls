import json
import os
import shlex

ADOPTION_IMAGE_ID = "sha256:af3b9fdcabc408cff5efca60ab94b58f479cc7bf15c4884eaf9ed30f7e167a1e"
ADOPTION_BUNDLE = json.dumps(
    {
        "version": 1,
        "image_id": ADOPTION_IMAGE_ID,
        "architecture": "x86_64",
        "boot_args": "console=ttyS0",
        "kernel_bytes": 7,
        "initrd_bytes": 7,
    },
    separators=(",", ":"),
)


def bundle_commands(directory: str) -> list[str]:
    quoted = shlex.quote(ADOPTION_BUNDLE)
    return [
        f"printf fixture > {directory}/kernel",
        f"printf fixture > {directory}/initrd",
        f"printf %s {quoted} > {directory}/boot-bundle.json",
        f"chmod 444 {directory}/kernel {directory}/initrd",
        f"chmod 600 {directory}/boot-bundle.json",
    ]


storage.start()
storage.wait_for_unit("multi-user.target")
storage.succeed(
    "zpool create -f -O compression=lz4 -O mountpoint=/source source /dev/vdb",
    "zpool create -f -O compression=lz4 -O mountpoint=/target target /dev/vdc",
    "zfs create -o lilly:host=source-only source/workload",
    "zfs create source/neighbor",
    "mkdir -p /source/.lilly-zfs /guest /received-guest",
    "touch /source/.lilly-zfs/source-authority",
    "printf neighbor > /source/neighbor/marker",
    "truncate -s 128M /source/workload/rootfs.ext4",
    "mkfs.ext4 -q -F /source/workload/rootfs.ext4",
    "mount -o loop /source/workload/rootfs.ext4 /guest",
    "dd if=/dev/urandom of=/guest/data bs=1M count=24 status=none",
    "printf final > /guest/phase",
    "sync",
    # ADR-0155: the single transfer snapshot is always taken of a stopped disk.
    "umount /guest",
    "zfs snapshot source/workload@lilly-b",
)


def prop(dataset: str, name: str) -> str:
    return storage.succeed(f"zfs get -Hp -o value {name} {dataset}").strip()


def guid(dataset: str) -> str:
    value = prop(dataset, "guid")
    assert value.isdigit() and int(value) > 0
    return value


source_guid = guid("source/workload")
final_guid = guid("source/workload@lilly-b")
expected_hash = storage.succeed("sha256sum /source/workload/rootfs.ext4 | cut -d ' ' -f 1").strip()
neighbor_guid = guid("source/neighbor")
receive = (
    "zfs receive -u -s -o mountpoint=/received -o canmount=noauto "
    "-o readonly=on -o compression=lz4 -o reservation=none "
    "-o refreservation=none -o exec=off -o setuid=off -o devices=off "
    "-o lilly:host=destination-only target/workload"
)

with subtest("interrupted full stream stays unmounted and resumes its exact snapshot"):
    storage.fail(
        "bash -o pipefail -c 'zfs send source/workload@lilly-b | head -c 4194304 | " + receive + "'"
    )
    assert prop("target/workload", "receive_resume_token") != "-"
    assert prop("target/workload", "mounted") == "no"
    storage.fail("zfs list target/workload@lilly-b")
    # The production token helper accepts the full-stream token only for its
    # exact snapshot with no parent; the token never leaves the machine.
    storage.succeed("python3 /etc/native-stream-probe.py validate-full")
    storage.succeed(
        "bash -o pipefail -c 'zfs send -t \"$(zfs get -Hp -o value "
        'receive_resume_token target/workload)" | ' + receive + "'"
    )
    assert prop("target/workload", "receive_resume_token") == "-"
    assert guid("target/workload@lilly-b") == final_guid
    destination_guid = guid("target/workload")
    assert destination_guid != source_guid
    assert prop("target/workload", "mounted") == "no"
    assert prop("target/workload", "readonly") == "on"
    assert prop("target/workload", "lilly:host") == "destination-only"
    assert prop("target/workload", "origin") == "-"

with subtest("an independent full receive binds its own destination filesystem GUID"):
    storage.succeed(
        "bash -o pipefail -c 'zfs send source/workload@lilly-b "
        "| zfs receive -u -s -o canmount=noauto -o readonly=on "
        "-o mountpoint=/fallback target/fallback'"
    )
    assert prop("target/fallback", "mounted") == "no"
    assert guid("target/fallback") not in [source_guid, destination_guid]
    assert guid("target/fallback@lilly-b") == final_guid
    storage.succeed("zfs mount target/fallback")
    assert (
        storage.succeed("sha256sum /fallback/rootfs.ext4 | cut -d ' ' -f 1").strip()
        == expected_hash
    )
    storage.succeed(
        "zfs unmount target/fallback",
        "zfs destroy target/fallback@lilly-b",
        "zfs destroy target/fallback",
    )

with subtest("aborting an incomplete full receive removes only its staging data"):
    storage.fail(
        "bash -o pipefail -c 'zfs send source/workload@lilly-b | head -c 4194304 "
        "| zfs receive -u -s -o canmount=noauto target/cancelled'"
    )
    assert prop("target/cancelled", "receive_resume_token") != "-"
    storage.succeed("zfs receive -A target/cancelled")
    storage.fail("zfs list target/cancelled")
    assert guid("target/workload") == destination_guid
    assert guid("source/workload") == source_guid

with subtest("production native helper streams, revokes and resumes actual ZFS receive"):
    storage.succeed("python3 /etc/native-stream-probe.py")
    for name in ["native-stream", "native-abort"]:
        storage.succeed(f"zfs set readonly=off canmount=on target/{name}; zfs mount target/{name}")
        actual = storage.succeed(f"sha256sum /{name}/rootfs.ext4 | cut -d ' ' -f 1").strip()
        assert actual == expected_hash
        storage.succeed(f"zfs destroy target/{name}@lilly-b; zfs destroy target/{name}")

with subtest(
    "destination-local journal verifies native staging without creating execution ownership"
):
    placement = "dddddddd-dddd-4ddd-8ddd-000000000002"
    received = "target/imports/vm-" + placement
    journal_path = "/import-pool/.lilly-zfs/imports/" + placement + "/import.json"
    storage.succeed("zfs create -o mountpoint=/import-pool target/imports")
    storage.succeed("received-check prepare", "received-check reject")
    storage.succeed(
        "python3 /etc/received-fixture.py", "received-check verify", "received-check verify"
    )
    record = json.loads(storage.succeed(f"cat {journal_path}"))
    storage.succeed("received-check prepare")
    assert json.loads(storage.succeed(f"cat {journal_path}")) == record
    # Orphan native data cannot reconstruct missing local receive intent.
    storage.succeed(
        f"mv {journal_path} /run/import-intent.json",
        "received-check reject-import",
        "received-check reject-cleanup",
    )
    storage.fail(f"test -e {journal_path}")
    storage.succeed(f"mv /run/import-intent.json {journal_path}")
    received_guid = guid(received)
    assert record["dataset_guid"] == received_guid and record["stream_state"] == "received"
    for key, wrong, correct in [
        ("readonly", "off", "on"),
        ("canmount", "on", "noauto"),
        ("exec", "on", "off"),
        ("setuid", "on", "off"),
        ("devices", "on", "off"),
    ]:
        storage.succeed(f"zfs set {key}={wrong} {received}", "received-check reject")
        storage.succeed(f"zfs set {key}={correct} {received}")
    storage.succeed(f"zfs mount {received}", "received-check reject", f"zfs unmount {received}")
    storage.succeed(f"zfs set lilly:nonce=foreign {received}", "received-check reject")
    nonce = record["nonce"]
    storage.succeed(
        f"zfs set lilly:nonce={nonce} target/imports; zfs inherit lilly:nonce {received}",
        "received-check reject",
    )
    storage.succeed(
        f"zfs set lilly:nonce={nonce} {received}; zfs inherit lilly:nonce target/imports"
    )
    storage.succeed(f"zfs snapshot {received}@foreign", "received-check reject")
    storage.succeed(f"zfs destroy {received}@foreign", "received-check verify")
    assert json.loads(storage.succeed(f"cat {journal_path}")) == record
    # A bound snapshot or filesystem cannot be substituted even with copied local markers.
    storage.succeed(f"zfs destroy {received}@lilly-b; zfs snapshot {received}@lilly-b")
    replacement_snapshot = guid(received + "@lilly-b")
    assert replacement_snapshot != final_guid
    storage.succeed("received-check reject")
    storage.succeed("received-check reject-import")
    assert guid(received + "@lilly-b") == replacement_snapshot
    storage.succeed(f"zfs destroy {received}@lilly-b; zfs destroy {received}")
    storage.fail("received-check receiver")
    storage.succeed("python3 /etc/received-fixture.py --replace")
    replacement_dataset = guid(received)
    assert replacement_dataset != received_guid
    storage.succeed("received-check reject")
    assert guid(received) == replacement_dataset
    storage.succeed("received-check reject-cleanup")
    assert guid(received) == replacement_dataset
    storage.succeed(f"zfs destroy {received}@lilly-b; zfs destroy {received}")
    storage.fail(f"test -e /import-pool/.lilly-zfs/active/{placement}")
    storage.succeed(
        f"if test -d /import-pool/vms/{placement}; then rmdir /import-pool/vms/{placement}; fi"
    )
    storage.succeed("received-check cleanup", "received-check cleanup")
    storage.succeed("received-check reject-prepare")
    storage.succeed("received-check reject-import")
    storage.fail(f"zfs list {received}", f"test -e /import-pool/.lilly-zfs/active/{placement}")
    storage.succeed(
        "mv /import-pool/.lilly-zfs/owner.json /run/import-parent-owner.json",
        "received-check reject-bind",
        "mv /run/import-parent-owner.json /import-pool/.lilly-zfs/owner.json",
    )

with subtest("retired imports abort a partial full receive without resurrection"):
    storage.succeed(
        "received-check prepare empty",
        "rm /import-pool/.lilly-zfs/imports/dddddddd-dddd-4ddd-8ddd-000000000008/import.json",
        "rmdir /import-pool/.lilly-zfs/imports/dddddddd-dddd-4ddd-8ddd-000000000008",
        "received-check cleanup-absent empty",
        "received-check cleanup-absent empty",
        "received-check cleanup empty",
        "received-check cleanup empty",
        "received-check reject-import empty",
    )
    for mode, suffix in [("partial", "000000000006")]:
        placement = "dddddddd-dddd-4ddd-8ddd-" + suffix
        received = "target/imports/vm-" + placement
        journal_path = "/import-pool/.lilly-zfs/imports/" + placement + "/import.json"
        # Fault markers fire only after the real native mutation; hashing scale
        # and accumulated pool state make small timeouts unreliable here.
        storage.succeed(f"received-check prepare {mode}")
        storage.succeed(f"python3 /etc/received-fixture.py {mode}")
        assert prop(received, "receive_resume_token") != "-"
        interrupted_guid = guid(received)
        storage.succeed(
            f"received-check resume {mode}",
            f"zfs set lilly:nonce=wrong {received}",
            f"received-check reject-resume {mode}",
        )
        # Restore the local marker inside the VM without exposing it in driver output.
        storage.succeed(
            "python3 -c "
            + shlex.quote(
                "import json,subprocess; "
                f"nonce=json.load(open({journal_path!r}))['nonce']; "
                f"subprocess.run(['zfs','set','lilly:nonce='+nonce,{received!r}],check=True)"
            )
        )
        storage.succeed(f"received-check resume {mode}")
        storage.succeed(
            f"zfs set exec=on {received}",
            f"received-check reject-resume {mode}",
            f"received-check reject-cleanup {mode}",
            f"received-check reject-resume {mode}",
        )
        assert guid(received) == interrupted_guid
        assert json.loads(storage.succeed(f"cat {journal_path}"))["phase"] == "retiring"
        storage.succeed(
            f"received-check reject-import {mode}",
            f"zfs set exec=off {received}",
            f"received-check cleanup {mode}",
            f"received-check cleanup {mode}",
        )
        storage.fail(f"zfs list {received}")
        retired = json.loads(storage.succeed(f"cat {journal_path}"))
        assert retired["phase"] == "retired" and retired["dataset_guid"] == interrupted_guid
        storage.succeed(f"received-check reject-import {mode}")
        assert guid("source/workload") == source_guid

with subtest("received rootfs adoption stages its source, pool and fault latch"):
    placement = "dddddddd-dddd-4ddd-8ddd-000000000004"
    received = "target/adoptions/vm-" + placement
    disk_path = "/adoption-pool/vms/" + placement + "/rootfs.ext4"
    claim_path = "/adoption-pool/.lilly-zfs/active/" + placement + "/claim.json"
    storage.succeed(
        "zfs create source/adoption",
        "cp --sparse=always /source/workload/rootfs.ext4 /source/adoption/rootfs.ext4",
        "truncate -s 2G /source/adoption/rootfs.ext4",
        *bundle_commands("/source/adoption"),
        "sync /source/adoption/rootfs.ext4",
        "zfs snapshot source/adoption@lilly-b",
        "zfs create -o mountpoint=/adoption-pool target/adoptions",
        "install -Dm0755 /etc/adoption-zfs-fault /run/adoption-tools/zfs",
    )
    expected = storage.succeed("sha256sum /source/adoption/rootfs.ext4 | cut -d ' ' -f 1").strip()
    storage.succeed(
        "received-check prepare adoption",
        "python3 /etc/received-fixture.py adoption",
        "received-check verify adoption",
    )
    storage.fail(f"test -e {claim_path}")
    original_guid = guid(received)
    for operation, state in [
        ("destroy", "importing"),
        ("mount", "import-pruned"),
        ("set", "import-publishing"),
    ]:
        unit = "adoption-interrupt-" + operation
        storage.succeed(
            "rm -f /run/adoption-operation-committed",
            f"systemd-run --unit={unit} --property=Type=exec --setenv=ADOPTION_PAUSE={operation} received-check adopt adoption",
        )
        storage.wait_for_file("/run/adoption-operation-committed", timeout=600)
        storage.succeed(f"systemctl kill --kill-whom=main --signal=KILL {unit}.service")
        storage.wait_until_fails(f"systemctl is-active --quiet {unit}.service")
        claim = json.loads(storage.succeed(f"cat {claim_path}"))
        assert claim["state"] == state and claim["dataset_guid"] == original_guid
        storage.succeed("received-check reject-prepare adoption")
        assert json.loads(storage.succeed(f"cat {claim_path}")) == claim
        if operation == "destroy":
            storage.fail(f"zfs list {received}@lilly-b")
            storage.succeed(
                f"zfs set lilly:nonce=foreign {received}", "received-check reject-adopt adoption"
            )
            storage.succeed(f"zfs set lilly:nonce={claim['nonce']} {received}")
        if operation == "mount":
            assert prop(received, "readonly") == "on" and prop(received, "mounted") == "yes"
            storage.succeed(
                f"zfs set readonly=off {received}",
                f"truncate -s 1G {disk_path}",
                f"zfs set readonly=on {received}",
                "received-check reject-adopt adoption",
            )
            assert json.loads(storage.succeed(f"cat {claim_path}")) == claim
            storage.succeed(
                f"zfs set readonly=off {received}",
                f"truncate -s 2G {disk_path}",
                f"zfs set readonly=on {received}",
            )
        if operation == "set":
            # A reboot can lose the mount after the durable publishing transition.
            storage.succeed(f"zfs unmount {received}")
    storage.succeed(
        "received-check adopt adoption",
        "received-check adopt adoption",
        "received-check reuse adoption",
        "received-check activate-stopped adoption",
        "received-check reject-cancel-activated adoption",
    )
    ready = json.loads(storage.succeed(f"cat {claim_path}"))
    assert ready["state"] == "ready" and ready["dataset_guid"] == original_guid
    assert prop(received, "readonly") == "off" and prop(received, "canmount") == "on"
    assert storage.succeed(f"sha256sum {disk_path} | cut -d ' ' -f 1").strip() == expected
    storage.fail(f"zfs list {received}@lilly-b")
    # Losing adopted data must not take the ordinary blank-image initialization path.
    storage.succeed(
        f"mv {disk_path} {disk_path}.retained",
        "received-check reject-adopt adoption",
        "received-check reject-prepare adoption",
    )
    storage.fail(f"test -e {disk_path}")
    storage.succeed(
        f"mv {disk_path}.retained {disk_path}",
        "received-check reuse adoption",
        "received-check reject-import-authority adoption",
    )

# The surviving placement 0004 checks moved into AdoptionCrashRecovery below:
# the state machine drives the ready sibling through the production reuse
# guard and re-verifies its guid and content.

with subtest("inception two-drive adoption publishes every drive and refuses incomplete sets"):
    placement = "dddddddd-dddd-4ddd-8ddd-000000000010"
    received = "target/adoptions/vm-" + placement
    directory = "/adoption-pool/vms/" + placement
    claim_path = "/adoption-pool/.lilly-zfs/active/" + placement + "/claim.json"
    storage.succeed(
        "zfs create source/adoption-inception",
        "cp --sparse=always /source/adoption/rootfs.ext4 /source/adoption-inception/rootfs.ext4",
        "truncate -s 2G /source/adoption-inception/rootfs.ext4",
        "truncate -s 274877906944 /source/adoption-inception/data.raw",
        "dd if=/dev/urandom of=/source/adoption-inception/data.raw bs=1M count=8 conv=notrunc status=none",
        *bundle_commands("/source/adoption-inception"),
        "sync /source/adoption-inception",
        "zfs snapshot source/adoption-inception@lilly-b",
    )
    expected_root = storage.succeed(
        "sha256sum /source/adoption-inception/rootfs.ext4 | cut -d ' ' -f 1"
    ).strip()
    expected_data = storage.succeed(
        "head -c 8388608 /source/adoption-inception/data.raw | sha256sum | cut -d ' ' -f 1"
    ).strip()
    inception_source_guid = guid("source/adoption-inception")
    storage.succeed(
        "received-check prepare adoption-inception",
        "python3 /etc/received-fixture.py adoption-inception",
        "received-check verify adoption-inception",
    )
    storage.fail(f"test -e {claim_path}")
    inception_received_guid = guid(received)
    # A renamed data drive (missing plus unexpected entry) cannot adopt.
    storage.succeed(
        f"zfs set readonly=off {received}",
        f"zfs mount {received}",
        f"mv {directory}/data.raw {directory}/unexpected.raw",
        "received-check reject-adopt adoption-inception",
    )
    storage.succeed(f"mv {directory}/unexpected.raw {directory}/data.raw")
    # A wrong-sized data drive cannot adopt; restoring the exact size recovers.
    storage.succeed(
        f"truncate -s 1073741824 {directory}/data.raw",
        "received-check reject-adopt adoption-inception",
    )
    storage.succeed(
        f"truncate -s 274877906944 {directory}/data.raw",
        f"zfs unmount {received}",
        f"zfs set readonly=on {received}",
    )
    storage.succeed(
        "received-check adopt adoption-inception",
        "received-check adopt adoption-inception",
        "received-check reuse adoption-inception",
    )
    ready = json.loads(storage.succeed(f"cat {claim_path}"))
    assert ready["state"] == "ready" and ready["dataset_guid"] == inception_received_guid
    assert sorted(storage.succeed(f"ls -A {directory}").split()) == [
        "boot-bundle.json",
        "data.raw",
        "initrd",
        "kernel",
        "rootfs.ext4",
    ]
    assert prop(received, "readonly") == "off" and prop(received, "canmount") == "on"
    storage.fail(f"zfs list {received}@lilly-b")
    assert (
        storage.succeed(f"sha256sum {directory}/rootfs.ext4 | cut -d ' ' -f 1").strip()
        == expected_root
    )
    assert (
        storage.succeed(
            f"head -c 8388608 {directory}/data.raw | sha256sum | cut -d ' ' -f 1"
        ).strip()
        == expected_data
    )
    assert storage.succeed(f"stat -c %s {directory}/data.raw").strip() == "274877906944"
    # Every drive publishes with the destination identity, never root or the source slot.
    for drive in ["rootfs.ext4", "data.raw"]:
        owner, mode = storage.succeed(f"stat -c '%u %a' {directory}/{drive}").split()
        assert owner == "1196615" and mode == "600", (drive, owner, mode)
    # An incomplete adopted drive set must not be blank-completed; the retained
    # marker refuses recreation exactly as for an adopted root disk.
    storage.succeed(
        f"mv {directory}/data.raw {directory}/data.retained",
        "received-check reject-prepare adoption-inception",
    )
    storage.fail(f"test -e {directory}/data.raw")
    storage.succeed(
        f"mv {directory}/data.retained {directory}/data.raw",
        "received-check cleanup adoption-inception",
    )
    storage.fail(f"zfs list {received}", f"test -e {claim_path}")
    assert guid("source/adoption-inception") == inception_source_guid

# Crash recovery of adopted copies is engine-driven from here on. This state
# machine replaces the two hand-enumerated kill ladders ("received rootfs
# adoption recovers snapshot, mount and policy interruptions" and "cancellation
# retires partially adopted and ready copies after physical cleanup") with
# engine-chosen rule orderings and fault points against the same guest
# fixtures. Each engine test case drives one fresh placement id. The engine
# replays identical draw sequences (shrinking, blob replay) against the same
# live VM, so teardown() and setup() retire every placement the case touched
# back to the byte-identical pre-case baseline instead of trusting leftovers.
from itertools import count as _count
from typing import Any

from hegel import (
    AssumptionRejected,
    MachineStateMachine,
    Pool,
    assume,
    invariant,
    rule,
    sampled_from,
)

ADOPTION_PREFIX = "dddddddd-dddd-4ddd-8ddd-"
ADOPTION_MODES = {"adoption": "000000000004", "adoption-cancel": "000000000009"}
ADOPTION_SOURCES = {
    "000000000004": "source/adoption",
    "000000000009": "source/adoption",
}
# Placement suffixes whose production reuse guard was exercised imperatively
# before this machine existed; they stay the safe reuse targets.
ADOPTION_REUSE_MODES = {
    "000000000004": "adoption",
}
ADOPTION_KILL_STATES = {
    "destroy": "importing",
    "mount": "import-pruned",
    "set": "import-publishing",
    "unmount": "import-deleting",
}
ADOPTION_CLAIM_STATES = {
    "importing",
    "import-pruned",
    "import-publishing",
    "ready",
    "import-deleting",
}
# Fault points latch only inside an adopt that still has the named native
# operation ahead of it. A durable claim state therefore admits only the
# strictly later points; re-running a point that already committed leaves no
# adoption-zfs-fault invocation to pause and the kill rule would wait in vain.
ADOPTION_KILL_ORDER = ["destroy", "mount", "set"]
ADOPTION_COMPLETED = {
    "staged": -1,
    "importing": 0,
    "import-pruned": 1,
    "import-publishing": 2,
}
ADOPTION_UNIT_SERIAL = _count()


def adoption_received(placement: str) -> str:
    return "target/adoptions/vm-" + placement


def adoption_claim_path(placement: str) -> str:
    return "/adoption-pool/.lilly-zfs/active/" + placement + "/claim.json"


def adoption_tombstone_path(placement: str) -> str:
    return "/adoption-pool/.lilly-zfs/deleted/" + placement + "/claim.json"


def adoption_journal_path(placement: str) -> str:
    return "/adoption-pool/.lilly-zfs/imports/" + placement + "/import.json"


def adoption_disk_path(placement: str) -> str:
    return "/adoption-pool/vms/" + placement + "/rootfs.ext4"


class AdoptionCrashRecovery(MachineStateMachine):
    """Crash, resume, cancel and retire one adopted placement per test case."""

    def __init__(self) -> None:
        # Pool of in-flight systemd units: start rules offer, the kill rule
        # has the engine draw (and thereby shrink) which operation dies.
        self.inflight = Pool()
        self.pending: dict[str, str] = {}
        self.units: list[str] = []
        self.touched: list[str] = []
        self.mode: str | None = None
        self.known: dict[str, str] = {}
        self.source_hashes: dict[str, str] = {}

    def setup(self) -> None:
        # Hegel replays identical draw sequences (shrinking, blob replay)
        # against the same live VM; restore the baseline assertion state
        # first so every replay of this case sees identical guest state.
        self._quiesce_units()
        for reset_mode in ADOPTION_MODES:
            self._reset_placement(reset_mode)
        # The one-shot transfer key store is fixture-local; reset it so a
        # replay never inherits a retired key from an earlier case's cancel
        # fixture cleanup.
        storage.succeed("rm -rf /var/lib/import-keys")
        for suffix, source in ADOPTION_SOURCES.items():
            self.source_hashes[suffix] = storage.succeed(
                f"sha256sum /{source}/rootfs.ext4 | cut -d ' ' -f 1"
            ).strip()
        for placement in self._listing("/adoption-pool/.lilly-zfs/active"):
            claim = self._read_json(adoption_claim_path(placement))
            assert claim is not None
            self.known[placement] = claim["dataset_guid"]
        for placement in self._listing("/adoption-pool/.lilly-zfs/deleted"):
            tombstone = self._read_json(adoption_tombstone_path(placement))
            assert tombstone is not None
            self.known[placement] = tombstone["dataset_guid"]
        for placement in self._listing("/adoption-pool/.lilly-zfs/imports"):
            if placement in self.known:
                continue
            journal = self._read_json(adoption_journal_path(placement))
            if journal is not None and journal.get("phase") != "retired":
                self.known[placement] = journal["dataset_guid"]

    def teardown(self) -> None:
        # Quiesce any operation the case left in flight, then retire every
        # placement the case touched back to the pre-case baseline. The engine
        # replays an identical draw sequence against persistent VM state; only
        # a restored baseline makes the replay's verdict identical.
        self._quiesce_units()
        for mode in self.touched:
            self._reset_placement(mode)
        # Destination ownership is one-shot by domain contract: the cancel
        # fixture's cleanup retires the transfer key permanently. Reset the
        # fixture-local key store so the next case (or a replay with identical
        # draws) ensures a fresh key instead of hitting :transfer_key_retired.
        storage.succeed("rm -rf /var/lib/import-keys")
        storage.succeed("test ! -e /var/lib/import-keys")

    def _quiesce_units(self) -> None:
        for unit in self.units:
            storage.succeed(f"systemctl kill --kill-whom=all --signal=KILL {unit}.service || true")
        storage.succeed("rm -f /run/adoption-operation-committed")

    def _reset_placement(self, mode: str) -> None:
        placement = ADOPTION_PREFIX + ADOPTION_MODES[mode]
        status = self._status(mode)
        if status == "fresh":
            return
        received = adoption_received(placement)
        if mode == "adoption-cancel":
            # The cancel fixture's cleanup has exactly one proven entry onto
            # retirement (import-pruned or import-deleting) and cannot retire a
            # ready copy; drive every residue through that proven chain:

            # deterministically with the same kill latches the rules use.
            def armed(action: str, point: str) -> None:
                unit = f"hegel-teardown-{mode}-{point}-{next(ADOPTION_UNIT_SERIAL)}"
                storage.succeed(
                    "rm -f /run/adoption-operation-committed",
                    f"systemd-run --unit={unit} --property=Type=exec "
                    f"--setenv=ADOPTION_PAUSE={point} received-check {action} {mode}",
                )
                storage.wait_for_file("/run/adoption-operation-committed", timeout=600)
                storage.succeed(
                    f"systemctl kill --kill-whom=all --signal=KILL {unit}.service || true",
                    "rm -f /run/adoption-operation-committed",
                )
                storage.wait_until_fails(f"systemctl is-active --quiet {unit}.service")

            if status in ("staged", "importing"):
                armed("adopt", "mount")
            if self._status(mode) == "import-pruned":
                armed("cleanup", "unmount")
            # import-deleting (or the now-retired state) falls through to the
            # idempotent doubled cleanup below.
        elif status in ("staged", "importing", "import-pruned", "import-publishing"):
            # Drive staging or crash residue forward to ready through the
            # proven resume path so retirement starts from one known state.
            storage.succeed(f"received-check adopt {mode}")
        # Retirement through the production cleanup is resumable and owns
        # every remaining residue (proven entry states: ready for adoption;
        # import-pruned and import-deleting for the cancel fixture).
        storage.succeed(f"received-check cleanup {mode}", f"received-check cleanup {mode}")
        if self._dataset_exists(received):
            storage.succeed(f"zfs destroy -r {received}")
        suffix = ADOPTION_MODES[mode]
        directory = "/adoption-pool/vms/" + placement
        # Reclaim assertion-visible leftovers (claims, tombstones, journals,
        # descriptors, VM intent) that the production retire intentionally
        # leaves behind; rules never consult them, only durable re-derivation.
        storage.succeed(
            f"rm -rf /adoption-pool/.lilly-zfs/active/{placement}",
            f"rm -rf /adoption-pool/.lilly-zfs/deleted/{placement}",
            f"rm -rf /adoption-pool/.lilly-zfs/imports/{placement}",
            f"rm -rf /var/lib/import-vms/{placement}",
            f"rm -f /run/adoption-descriptor-{suffix}.json",
            f"rm -rf /run/adoption-image-{suffix}",
            f"if test -d {directory}; then rmdir {directory}; fi",
        )

    def _listing(self, path: str) -> list[str]:
        quoted = shlex.quote(path)
        return storage.succeed(f"sh -c 'ls -A {quoted} 2>/dev/null || true'").split()

    def _read_json(self, path: str) -> dict[str, Any] | None:
        quoted = shlex.quote(path)
        document = storage.succeed(f"sh -c 'if test -e {quoted}; then cat {quoted}; fi'").strip()
        if not document:
            return None
        return json.loads(document)

    def _dataset_exists(self, name: str) -> bool:
        return storage.execute(f"zfs list {name}")[0] == 0

    def _status(self, mode: str) -> str:
        placement = ADOPTION_PREFIX + ADOPTION_MODES[mode]
        claim = self._read_json(adoption_claim_path(placement))
        if claim is not None:
            state = claim["state"]
            assert state in ADOPTION_CLAIM_STATES, (placement, state)
            return state
        if self._read_json(adoption_tombstone_path(placement)) is not None:
            return "deleted"
        if self._dataset_exists(adoption_received(placement)):
            return "staged"
        journal = self._read_json(adoption_journal_path(placement))
        if journal is not None and journal.get("phase") == "retired":
            return "retired"
        return "fresh"

    def _require_mode(self) -> str:
        if self.mode is None or self.pending:
            raise AssumptionRejected("no placement selected or an operation is in flight")
        return self.mode

    def _verify_ready_siblings(self) -> None:
        # Sibling adopted placements must survive this case's crashes and
        # retirements: stable dataset guid, intact content and (for the
        # proven modes) the production reuse guard still succeeds.
        names = storage.succeed("zfs list -d 1 -H -o name target/adoptions").split()
        for name in names:
            if not name.startswith("target/adoptions/vm-"):
                continue
            placement = name.removeprefix("target/adoptions/vm-")
            claim = self._read_json(adoption_claim_path(placement))
            if claim is None or claim["state"] != "ready":
                continue
            assert guid(name) == claim["dataset_guid"], placement
            suffix = placement.removeprefix(ADOPTION_PREFIX)
            if suffix in ADOPTION_SOURCES:
                hash_path = adoption_disk_path(placement)
                actual = storage.succeed(f"sha256sum {hash_path} | cut -d ' ' -f 1").strip()
                assert actual == self.source_hashes[suffix], placement
            if suffix in ADOPTION_REUSE_MODES:
                storage.succeed(f"received-check reuse {ADOPTION_REUSE_MODES[suffix]}")

    @rule(weight=4, mode=sampled_from(["adoption", "adoption-cancel"]))
    def prepare(self, mode: str) -> None:
        assume(self.mode is None and not self.pending, "one adoption per test case")
        status = self._status(mode)
        assume(status in ("fresh", "staged"), "placement lifecycle already driven")
        # Track before the first guest mutation: even a rule that dies here
        # must have its residue retired by teardown before any replay.
        self.touched.append(mode)
        placement = ADOPTION_PREFIX + ADOPTION_MODES[mode]
        if status == "fresh":
            storage.succeed(
                f"received-check prepare {mode}",
                f"python3 /etc/received-fixture.py {mode}",
                f"received-check verify {mode}",
                f"received-check verify {mode}",
            )
        else:
            # Reattach to staging a prior case left behind; verify is
            # idempotent and re-proves the durable intent matches native data.
            storage.succeed(f"received-check verify {mode}")
        storage.fail(f"test -e {adoption_claim_path(placement)}")
        self.mode = mode
        self.known[placement] = guid(adoption_received(placement))

    @rule(weight=2)
    def verify(self) -> None:
        mode = self._require_mode()
        assume(self._status(mode) == "staged", "verify requires staged native data")
        storage.succeed(f"received-check verify {mode}")

    @rule(weight=2, point=sampled_from(["destroy", "mount", "set"]))
    def start_adopt_at_point(self, point: str) -> None:
        mode = self._require_mode()
        status = self._status(mode)
        # Cancel-mode adoption may only be driven to import-pruned: the cancel
        # fixture's cleanup has no proven transition from a ready copy, so a
        # kill-at-"set" residue (import-publishing) could resume to ready and
        # become unretirable.
        assume(
            not (mode == "adoption-cancel" and point == "set"),
            "cancel-mode retirement is proven up to import-pruned only",
        )
        assume(
            status in ADOPTION_COMPLETED,
            "adoption is not resumable from this durable state",
        )
        assume(
            ADOPTION_KILL_ORDER.index(point) > ADOPTION_COMPLETED[status],
            "the named native operation already committed for this adoption",
        )
        unit = f"hegel-adopt-{mode}-{point}-{next(ADOPTION_UNIT_SERIAL)}"
        storage.succeed(
            "rm -f /run/adoption-operation-committed",
            f"systemd-run --unit={unit} --property=Type=exec "
            f"--setenv=ADOPTION_PAUSE={point} received-check adopt {mode}",
        )
        self.pending[unit] = point
        self.units.append(unit)
        self.inflight.add(unit)

    # @cc [owner:ghuntley,label:verification] adoption-crashes-follow-real-native-effects
    # Adoption recovery MUST be exercised after actual ZFS effects and caller death;
    # editing durable claim states to simulate those effects is insufficient.
    @rule(weight=1)
    def kill_when_committed(self) -> None:
        unit = self.inflight.draw(consume=True)
        operation = self.pending.pop(unit)
        mode = self._require_mode()
        placement = ADOPTION_PREFIX + ADOPTION_MODES[mode]
        received = adoption_received(placement)
        claim_path = adoption_claim_path(placement)
        storage.wait_for_file("/run/adoption-operation-committed", timeout=600)
        storage.succeed(f"systemctl kill --kill-whom=main --signal=KILL {unit}.service")
        storage.wait_until_fails(f"systemctl is-active --quiet {unit}.service")
        claim = self._read_json(claim_path)
        assert claim is not None
        assert claim["state"] == ADOPTION_KILL_STATES[operation]
        assert claim["dataset_guid"] == self.known[placement]
        storage.succeed(f"received-check reject-prepare {mode}")
        assert self._read_json(claim_path) == claim
        if operation == "destroy":
            storage.fail(f"zfs list {received}@lilly-b")
            storage.succeed(
                f"zfs set lilly:nonce=foreign {received}",
                f"received-check reject-adopt {mode}",
                f"zfs set lilly:nonce={claim['nonce']} {received}",
            )
        if operation == "mount":
            assert prop(received, "readonly") == "on"
            assert prop(received, "mounted") == "yes"
            disk_path = adoption_disk_path(placement)
            storage.succeed(
                f"zfs set readonly=off {received}",
                f"truncate -s 1G {disk_path}",
                f"zfs set readonly=on {received}",
                f"received-check reject-adopt {mode}",
            )
            assert self._read_json(claim_path) == claim
            storage.succeed(
                f"zfs set readonly=off {received}",
                f"truncate -s 2G {disk_path}",
                f"zfs set readonly=on {received}",
            )
        if operation == "set" and prop(received, "mounted") == "yes":
            # A reboot can lose the mount after the durable publishing transition.
            storage.succeed(f"zfs unmount {received}")
        if operation == "unmount":
            assert prop(received, "mounted") == "no"

    @rule(weight=4)
    def adopt_retry(self) -> None:
        mode = self._require_mode()
        # Cancel mode drives forward exclusively through kill-latched
        # `start_adopt_at_point` (lands import-pruned); a plain resume could
        # run past the mount point into ready, which the cancel fixture's
        # cleanup cannot retire.
        assume(mode != "adoption-cancel", "cancel mode resumes via kill-latched adopt only")
        assume(
            self._status(mode) in ("staged", "importing", "import-pruned", "import-publishing"),
            "no verified staging or crash residue to adopt from",
        )
        placement = ADOPTION_PREFIX + ADOPTION_MODES[mode]
        received = adoption_received(placement)
        storage.succeed(f"received-check adopt {mode}", f"received-check adopt {mode}")
        ready = self._read_json(adoption_claim_path(placement))
        assert ready is not None
        assert ready["state"] == "ready" and ready["dataset_guid"] == self.known[placement]
        assert prop(received, "readonly") == "off" and prop(received, "canmount") == "on"
        storage.fail(f"zfs list {received}@lilly-b")
        storage.succeed(
            f"received-check activate-stopped {mode}",
            f"received-check reject-cancel-activated {mode}",
        )
        self._verify_ready_siblings()

    @rule(weight=3)
    def reuse(self) -> None:
        mode = self._require_mode()
        assume(self._status(mode) == "ready", "reuse requires a fully adopted disk")
        placement = ADOPTION_PREFIX + ADOPTION_MODES[mode]
        disk_path = adoption_disk_path(placement)
        storage.succeed(f"received-check reuse {mode}")
        # Losing adopted data must not take the ordinary blank-image
        # initialization path; the retained marker forces refusal instead.
        storage.succeed(
            f"mv {disk_path} {disk_path}.retained",
            f"received-check reject-adopt {mode}",
            f"received-check reject-prepare {mode}",
        )
        storage.fail(f"test -e {disk_path}")
        storage.succeed(
            f"mv {disk_path}.retained {disk_path}",
            f"received-check reuse {mode}",
            f"received-check reject-import-authority {mode}",
        )
        self._verify_ready_siblings()

    # The faulted cancellation kill is bound to the cancel fixture: destination
    # cleanup unmounts the adopted copy, which latches ADOPTION_PAUSE=unmount.
    @rule(weight=1)
    def cancel(self) -> None:
        mode = self._require_mode()
        assume(mode == "adoption-cancel", "faulted retirement uses the cancel fixture")
        assume(
            self._status(mode) == "import-pruned",
            "the cleanup fault latch needs the adopted copy still mounted",
        )
        unit = f"hegel-cancel-{mode}-{next(ADOPTION_UNIT_SERIAL)}"
        storage.succeed(
            "rm -f /run/adoption-operation-committed",
            f"systemd-run --unit={unit} --property=Type=exec "
            f"--setenv=ADOPTION_PAUSE=unmount received-check cleanup {mode}",
        )
        self.pending[unit] = "unmount"
        self.units.append(unit)
        self.inflight.add(unit)

    @rule(weight=3)
    def cleanup(self) -> None:
        mode = self._require_mode()
        status = self._status(mode)
        if mode == "adoption-cancel":
            assume(
                status == "import-deleting",
                "cancellation cleanup is proven from the killed unmount residue only",
            )
        else:
            assume(status == "ready", "retirement requires a ready adopted disk")
        placement = ADOPTION_PREFIX + ADOPTION_MODES[mode]
        if mode == "adoption-cancel":
            # Retire first, then prove the tombstone refuses: adopt attempted
            # against the in-flight import-deleting residue is a resume, not a
            # refusal, so the negative probes must follow the doubled cleanup.
            storage.succeed(
                f"received-check cleanup {mode}",
                f"received-check cleanup {mode}",
                f"received-check reject-adopt {mode}",
                f"received-check reject-prepare {mode}",
            )
            storage.fail(
                f"zfs list {adoption_received(placement)}",
                f"test -e /adoption-pool/.lilly-zfs/active/{placement}",
            )
            tombstone = self._read_json(adoption_tombstone_path(placement))
            assert tombstone is not None
            assert tombstone["state"] == "deleted"
            assert tombstone["dataset_guid"] == self.known[placement]
        else:
            storage.succeed(
                f"received-check cleanup {mode}",
                f"received-check cleanup {mode}",
                f"received-check reject-adopt {mode}",
                f"received-check reject-prepare {mode}",
            )
            storage.fail(f"zfs list {adoption_received(placement)}")
        self._verify_ready_siblings()

    @invariant(always=True)
    def claim_states_are_legal(self) -> None:
        if self.pending:
            # A committed-but-not-yet-killed operation may be mid-transition.
            return
        for placement in self._listing("/adoption-pool/.lilly-zfs/active"):
            claim = self._read_json(adoption_claim_path(placement))
            assert claim is not None
            assert claim["state"] in ADOPTION_CLAIM_STATES, (placement, claim["state"])
            received = adoption_received(placement)
            if self._dataset_exists(received):
                assert guid(received) == claim["dataset_guid"]
        for placement in self._listing("/adoption-pool/.lilly-zfs/deleted"):
            tombstone = self._read_json(adoption_tombstone_path(placement))
            assert tombstone is not None
            assert tombstone["state"] == "deleted", placement
            assert not self._dataset_exists(adoption_received(placement))

    @invariant(always=True)
    def dataset_guids_stable(self) -> None:
        for placement, recorded in self.known.items():
            received = adoption_received(placement)
            if self._dataset_exists(received):
                assert guid(received) == recorded, placement

    @invariant()
    def foreign_nonce_still_rejected(self) -> None:
        if self.pending or self.mode is None:
            return
        mode = self.mode
        if self._status(mode) not in ("staged", "importing", "import-pruned", "import-publishing"):
            return
        placement = ADOPTION_PREFIX + ADOPTION_MODES[mode]
        received = adoption_received(placement)
        storage.succeed(
            f"zfs set lilly:nonce=foreign {received}",
            f"received-check reject-adopt {mode}",
        )
        record = self._read_json(adoption_claim_path(placement))
        if record is None:
            record = self._read_json(adoption_journal_path(placement))
        assert record is not None
        storage.succeed(f"zfs set lilly:nonce={record['nonce']} {received}")

    @invariant()
    def received_policy_bits(self) -> None:
        if self.pending or self.mode is None:
            return
        mode = self.mode
        status = self._status(mode)
        placement = ADOPTION_PREFIX + ADOPTION_MODES[mode]
        received = adoption_received(placement)
        if status == "ready":
            assert prop(received, "readonly") == "off"
            assert prop(received, "canmount") == "on"
        elif status in ("staged", "importing", "import-pruned"):
            assert prop(received, "readonly") == "on"
            for bit in ("exec", "setuid", "devices"):
                assert prop(received, bit) == "off"


AdoptionCrashRecovery.run()

with subtest("verified disk survives nonrecursive source reclamation"):
    storage.succeed("zfs mount target/workload")
    actual_hash = storage.succeed("sha256sum /received/rootfs.ext4 | cut -d ' ' -f 1").strip()
    assert actual_hash == expected_hash
    assert storage.succeed("ls -A /received").strip() == "rootfs.ext4"
    storage.succeed(
        "mount -o loop,ro,noload /received/rootfs.ext4 /received-guest",
        "test $(cat /received-guest/phase) = final",
        "test $(stat -c %s /received-guest/data) = 25165824",
        "umount /received-guest",
        "zfs destroy source/workload@lilly-b",
        "zfs destroy source/workload",
    )
    storage.fail("zfs list source/workload")
    assert guid("source/neighbor") == neighbor_guid
    storage.succeed(
        "test $(cat /source/neighbor/marker) = neighbor",
        "test -f /source/.lilly-zfs/source-authority",
        "zfs destroy target/workload@lilly-b",
        "zfs set readonly=off target/workload",
        "mount -o loop /received/rootfs.ext4 /received-guest",
        "test $(cat /received-guest/phase) = final",
        "printf activated > /received-guest/activation",
        "sync",
        "umount /received-guest",
    )
    assert guid("target/workload") == destination_guid
    assert prop("target/workload", "usedbysnapshots") == "0"

with open(os.path.join(os.environ["out"], "transfer-identities.json"), "w") as output:  # noqa: SIM112 - Nix provides lowercase $out
    json.dump(
        {
            "source_dataset_guid": source_guid,
            "destination_dataset_guid": destination_guid,
            "final_snapshot_guid": final_guid,
        },
        output,
    )
