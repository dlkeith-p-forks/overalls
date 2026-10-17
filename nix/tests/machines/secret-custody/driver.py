# Secret custody lifecycle driver.
#
# One-shot linear probes stay imperative (initial publication, module
# publication boundaries, generation switching, host recipient rotation and
# replacement recovery). CustodyStateMachine lets the Hegel engine explore
# seal/recover/rotate/missing/restore interleavings with the invariant set
# enforced at every join point. The appended Hegel epilogue executes the
# registered properties and fails the test on a counterexample.
import json
import os
import tempfile
from pathlib import Path

from hegel import (
    MachineStateMachine,
    TestCase,
    assume,
    given,
    invariant,
    lists,
    rule,
    text,
)

GUEST_VERIFY_DIR = "/run/overalls-hegel-verify"

# Driver-side scratch for drawn payloads: private to this process, never in
# a machine out_dir (machine out_dirs are collected into the test result).
driver_run = (
    Path(os.environ.get("XDG_RUNTIME_DIR") or tempfile.gettempdir()) / "overalls-secret-custody"
)
driver_run.mkdir(mode=0o700, exist_ok=True)


def wait_ready() -> None:
    primary.wait_until_succeeds(
        "curl --fail --silent --cacert /run/overalls-test/ca.crt https://localhost:4443/health/ready",
        timeout=120,
    )


def _environment_legal(value: str) -> bool:
    return all(
        not (0xFDD0 <= ord(character) <= 0xFDEF or ord(character) & 0xFFFF in (0xFFFE, 0xFFFF))
        for character in value
    )


# systemd EnvironmentFile delivery rejects NULs, surrogates and Unicode
# noncharacters (the module refuses those); draw from the valid domain.
secret_text = text(
    min_size=1,
    max_size=128,
    exclude_categories=("Cs",),
    exclude_characters="\0\ufeff",
).filter(_environment_legal)

start_all()
primary.wait_for_unit("postgresql-setup.service")
primary.wait_for_unit("overalls-secrets-marshall.service")
primary.succeed("systemctl start overalls-test-migrate.service")
wait_ready()
primary.succeed(f"install -d -m 0700 {GUEST_VERIFY_DIR}")

with subtest("selected secrets reach the real unprivileged Marshall release"):
    primary.succeed("test $(stat -c %a /run/overalls-secrets/marshall/environment) = 600")
    primary.succeed("test $(stat -c %a /run/overalls-secrets/marshall/serper.key) = 600")
    primary.succeed("test $(stat -c %a /run/overalls-secrets/marshall) = 700")
    primary.succeed("test ! -e /run/overalls-secrets-marshall/identity")
    uid = primary.succeed(
        "stat -c %u /proc/$(systemctl show -p MainPID --value marshall-primary.service)"
    ).strip()
    assert uid != "0"
    primary.fail(
        f"setpriv --reuid={uid} --regid={uid} --clear-groups cat /etc/ssh/ssh_host_ed25519_key"
    )
    primary.fail(
        f"setpriv --reuid={uid} --regid={uid} --clear-groups cat /run/overalls-secrets/marshall/environment"
    )

with subtest("publication, cleanup and capture boundaries hold under interruption"):
    primary.succeed(f"python {module_boundaries} {prepare_module}", timeout=180)


# @cc [owner:ghuntley,label:verification] environment-parser-roundtrip
# Generated values MUST be checked through actual systemd EnvironmentFile
# delivery, without a shell parser substitute or secret-bearing diagnostics.
@given(values=lists(secret_text, min_size=4, max_size=4))
def environment_file_roundtrip(tc: TestCase, values: list[str]) -> None:
    payload = {"SYNTHETIC_" + str(index): value for index, value in enumerate(values)}
    payload["SYNTHETIC_ESCAPES"] = "  a'\"\\\n\r\t$HOME `command` %n #;= 🐈  "
    # The guest receives drawn secrets only through a private file. With
    # properties.redact = true the harness also never prints them itself.
    descriptor, host_name = tempfile.mkstemp(dir=driver_run, prefix="expected-", suffix=".json")
    try:
        with os.fdopen(descriptor, "w") as stream:
            stream.write(json.dumps(payload))
        primary.copy_from_host(host_name, GUEST_VERIFY_DIR + "/expected.json")
        primary.succeed(
            f"python {seal_fixture} verify {GUEST_VERIFY_DIR}/expected.json {prepare_module}",
            timeout=180,
        )
    finally:
        Path(host_name).unlink(missing_ok=True)
        primary.succeed(f"rm -f {GUEST_VERIFY_DIR}/expected.json {GUEST_VERIFY_DIR}/environment")


with subtest("switching NixOS generations preserves the host identity"):
    fingerprint = primary.succeed(
        "ssh-keygen -l -E sha256 -f /etc/ssh/ssh_host_ed25519_key.pub"
    ).strip()
    primary.succeed(
        "/run/current-system/specialisation/secret-rebuild/bin/switch-to-configuration test > /run/overalls-test/activation.log 2>&1",
        timeout=120,
    )
    primary.succeed("test $(cat /etc/overalls-test-generation) = rebuilt")
    assert (
        primary.succeed("ssh-keygen -l -E sha256 -f /etc/ssh/ssh_host_ed25519_key.pub").strip()
        == fingerprint
    )
    primary.succeed("systemctl stop marshall-primary.service")
    primary.succeed("systemctl restart overalls-secrets-marshall.service")
    primary.succeed(f"python {seal_fixture} recover")
    primary.succeed("systemctl start marshall-primary.service")
    wait_ready()

with subtest("host recipient rotation verifies the new key before retiring the old key"):
    fingerprint = primary.succeed(
        "ssh-keygen -l -E sha256 -f /etc/ssh/ssh_host_ed25519_key.pub"
    ).strip()
    primary.succeed(f"python {seal_fixture} stage-host")
    primary.succeed(f"python {seal_fixture} recover")
    primary.succeed("systemctl stop marshall-primary.service")
    primary.succeed(f"python {seal_fixture} install-host")
    assert (
        primary.succeed("ssh-keygen -l -E sha256 -f /etc/ssh/ssh_host_ed25519_key.pub").strip()
        != fingerprint
    )
    primary.succeed("systemctl restart sshd.service overalls-secrets-marshall.service")
    primary.succeed("systemctl start marshall-primary.service")
    wait_ready()
    primary.succeed(f"python {seal_fixture} verify-running")
    primary.succeed(f"python {seal_fixture} retire-host")
    primary.succeed("systemctl stop marshall-primary.service")
    primary.succeed("systemctl restart overalls-secrets-marshall.service")
    primary.succeed("systemctl start marshall-primary.service")
    wait_ready()
    primary.succeed(f"python {seal_fixture} verify-running")
    primary.succeed(f"python {seal_fixture} recover")
    primary.succeed(f"python {seal_fixture} check-journal")

with subtest("operator recovery delivers the unchanged bundle to a separately keyed replacement"):
    wrong.copy_from_machine("/etc/ssh/ssh_host_ed25519_key.pub", "replacement-public")
    primary.copy_from_host(
        str(wrong.out_dir / "replacement-public/ssh_host_ed25519_key.pub"),
        "/run/overalls-test-sealed/replacement.pub",
    )
    primary.succeed(f"python {seal_fixture} replace-host")
    primary.copy_from_machine(
        "/run/overalls-test-sealed/replacement.enc.json", "replacement-encrypted"
    )
    wrong.copy_from_host(
        str(primary.out_dir / "replacement-encrypted/replacement.enc.json"),
        "/run/overalls-test-sealed/marshall.enc.json",
    )
    wrong.succeed("systemctl restart overalls-secrets-marshall.service")
    wrong.succeed(f"python {seal_fixture} verify-replacement")
    wrong.succeed(
        "test ! -e /run/overalls-secrets-marshall/identity && test ! -e /run/overalls-test-sealed/verification.age"
    )
    # Return the adversarial node to a bundle-free baseline so the state
    # machine's adoption-refusal invariant can prove absence of publication.
    wrong.succeed("rm -rf /run/overalls-secrets/marshall /run/overalls-secrets-marshall")
    # verify-replacement staged wrong's own host key as the recipient; the
    # refusal invariant needs a genuinely foreign identity again. Rotate it.
    wrong.succeed("rm -f /etc/ssh/ssh_host_ed25519_key /etc/ssh/ssh_host_ed25519_key.pub")
    wrong.succeed("systemctl restart sshd-keygen.service")
    wrong.succeed("systemctl reset-failed overalls-secrets-marshall.service || true")


class CustodyStateMachine(MachineStateMachine):
    """Engine-explored custody lifecycle over the live machines.

    A driver-side flag models the fenced macro state (a bundle with missing
    values was staged: the secrets unit is failed and Marshall is fenced
    off). Rules are idempotent and converge back to a healthy consistently
    published system so engine-chosen sequences never wedge the machines.
    """

    def setup(self) -> None:
        self.fenced = False
        self.foreign_copies = 0
        # Cases share the live machines; a prior teardown may have just
        # restarted Marshall while unfencing. Wait for the healthy baseline
        # before the initial invariant checks run.
        primary.wait_for_unit("overalls-secrets-marshall.service")
        wait_ready()

    def teardown(self) -> None:
        # Restore the complete bundle if a case ended (or failed) fenced, so
        # the next case starts from the healthy baseline.
        if self.fenced:
            primary.succeed(f"python {seal_fixture} seal")
            primary.succeed("systemctl restart overalls-secrets-marshall.service")
            primary.succeed("systemctl start marshall-primary.service")
            self.fenced = False

    @rule(weight=3)
    def seal_and_recover(self) -> None:
        assume(not self.fenced)
        primary.succeed(f"python {seal_fixture} seal")
        primary.succeed("systemctl restart overalls-secrets-marshall.service")
        primary.succeed(f"python {seal_fixture} recover")

    @rule(weight=3)
    def operator_recovery(self) -> None:
        assume(not self.fenced)
        primary.succeed(f"python {seal_fixture} recover")

    @rule(weight=2)
    def restart_secrets_unit(self) -> None:
        assume(not self.fenced)
        primary.succeed("systemctl restart overalls-secrets-marshall.service")

    @rule(weight=2)
    def restart_marshall(self) -> None:
        assume(not self.fenced)
        primary.succeed("systemctl stop marshall-primary.service")
        primary.succeed("systemctl start marshall-primary.service")
        wait_ready()
        primary.succeed(f"python {seal_fixture} verify-running")

    @rule(weight=1)
    def publish_shared_bundle(self) -> None:
        # The shared bundle needs only FIXTURE_TOKEN, so it stays publishable
        # even while the marshall bundle is fenced on missing values.
        primary.succeed("systemctl restart overalls-secrets-shared.service")
        primary.succeed(
            "setpriv --reuid=fixture-reader --regid=fixture-readers --init-groups "
            "head -c0 /run/overalls-secrets/shared/token"
        )
        primary.fail(
            "setpriv --reuid=fixture-outsider --regid=nogroup --init-groups "
            "head -c0 /run/overalls-secrets/shared/token"
        )
        primary.fail(
            "setpriv --reuid=fixture-reader --regid=fixture-readers --init-groups "
            "head -c0 /etc/ssh/ssh_host_ed25519_key"
        )

    @rule(weight=1)
    def stage_missing_input(self) -> None:
        assume(not self.fenced)
        primary.succeed(
            "cp /run/overalls-secrets/marshall/environment /run/overalls-test/previous.env"
        )
        primary.succeed(f"python {seal_fixture} missing")
        primary.succeed("systemctl stop marshall-primary.service")
        primary.fail("systemctl restart overalls-secrets-marshall.service")
        self.fenced = True

    @rule(weight=1)
    def restore_complete_bundle(self) -> None:
        assume(self.fenced)
        primary.succeed(
            "cmp /run/overalls-test/previous.env /run/overalls-secrets/marshall/environment"
        )
        primary.fail("systemctl start marshall-primary.service")
        primary.succeed(f"python {seal_fixture} seal")
        primary.succeed("systemctl restart overalls-secrets-marshall.service")
        primary.succeed("systemctl start marshall-primary.service")
        wait_ready()
        self.fenced = False

    @rule(weight=1)
    def rotate_credentials(self) -> None:
        assume(not self.fenced)
        primary.succeed(f"python {seal_fixture} verify-running")
        primary.succeed(f"python {seal_fixture} rotate")
        primary.succeed(f"python {seal_fixture} verify-previous")
        primary.succeed("systemctl stop marshall-primary.service")
        primary.succeed("systemctl restart overalls-secrets-marshall.service")
        primary.fail("systemctl is-active --quiet marshall-primary.service")
        primary.succeed("systemctl start marshall-primary.service")
        wait_ready()
        primary.succeed(f"python {seal_fixture} verify-running")
        primary.succeed(f"python {seal_fixture} recover")
        primary.succeed(f"python {seal_fixture} check-journal")

    @rule(weight=0.25)
    def reboot_preserves_host_identity(self) -> None:
        assume(not self.fenced)
        fingerprint = primary.succeed(
            "ssh-keygen -l -E sha256 -f /etc/ssh/ssh_host_ed25519_key.pub"
        ).strip()
        # The driver's default QEMU exits on reboot; retain the disk and start again.
        primary.reboot()
        primary.wait_for_shutdown()
        primary.start()
        primary.wait_for_unit("multi-user.target")
        # The boot-time fixture rewrites /run/overalls-test (fresh values) and
        # the boot-time seal re-encrypts them; recovery must see them.
        primary.wait_for_unit("overalls-secrets-marshall.service")
        primary.succeed(f"python {seal_fixture} recover")
        assert (
            primary.succeed("ssh-keygen -l -E sha256 -f /etc/ssh/ssh_host_ed25519_key.pub").strip()
            == fingerprint
        )
        wait_ready()

    @invariant(always=True)
    def published_bundle_modes_are_strict(self) -> None:
        primary.succeed("test $(stat -c %a /run/overalls-secrets/marshall/environment) = 600")
        primary.succeed("test $(stat -c %a /run/overalls-secrets/marshall/serper.key) = 600")
        primary.succeed("test $(stat -c %a /run/overalls-secrets/marshall) = 700")
        # The derived private decryption identity must never persist.
        primary.succeed("test ! -e /run/overalls-secrets-marshall/identity")
        primary.succeed(
            "test ! -e /run/overalls-secrets/shared "
            "|| test $(stat -c %a /run/overalls-secrets/shared) = 750"
        )
        primary.succeed(
            "test ! -e /run/overalls-secrets/shared/token "
            "|| test $(stat -c %a /run/overalls-secrets/shared/token) = 640"
        )

    @invariant(always=True)
    def marshall_health_tracks_fencing(self) -> None:
        if self.fenced:
            # Bad input fences startup: Marshall must stay stopped.
            primary.fail("systemctl is-active --quiet marshall-primary.service")
            return
        # Post-restart transitions are legal; poll instead of demanding the
        # health endpoint respond on the first probe of a join point.
        wait_ready()

    @invariant(always=True)
    def previous_bundle_preserved_on_bad_input(self) -> None:
        if not self.fenced:
            return
        # While the staged bundle lacks required values, the last good
        # publication must be bit-identical and the secrets unit failed.
        primary.succeed(
            "cmp /run/overalls-test/previous.env /run/overalls-secrets/marshall/environment"
        )
        primary.fail("systemctl is-active --quiet overalls-secrets-marshall.service")

    @invariant()
    def wrong_host_cannot_decrypt(self) -> None:
        # A different SSH host identity cannot decrypt this bundle, no matter
        # what lifecycle state primary is in. Non-always: sampled at
        # engine-chosen join points (each check costs a VM round-trip).
        wrong.wait_for_unit("sshd.service")
        self.foreign_copies += 1
        staging = f"foreign-encrypted-{self.foreign_copies}"
        primary.copy_from_machine("/run/overalls-test-sealed/marshall.enc.json", staging)
        wrong.succeed("install -d -m 0700 /run/overalls-test-sealed")
        wrong.copy_from_host(
            str(primary.out_dir / staging / "marshall.enc.json"),
            "/run/overalls-test-sealed/marshall.enc.json",
        )
        wrong.fail("systemctl start overalls-secrets-marshall.service")
        wrong.succeed("test ! -e /run/overalls-secrets/marshall")
        wrong.succeed("test ! -e /run/overalls-secrets-marshall/identity")


CustodyStateMachine.run()
