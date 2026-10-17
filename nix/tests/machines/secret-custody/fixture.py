"""Seal or verify synthetic deployment credentials without displaying them."""

import importlib.util
import json
import os
import secrets
import shlex
import subprocess
import sys
import types
from pathlib import Path


def run(
    arguments: list[str],
    *,
    env: dict[str, str] | None = None,
    input: bytes | None = None,
    timeout: int = 60,
) -> bytes:
    result = subprocess.run(
        arguments,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=timeout,
        env=env,
        input=input,
    )
    if result.returncode:
        raise ValueError("fixture tool failed")
    return result.stdout


def identity_environment(root: Path, identity: Path) -> dict[str, str]:
    return {
        "PATH": os.environ["PATH"],
        "XDG_CONFIG_HOME": str(root),
        "SOPS_AGE_KEY_FILE": str(identity),
        "SOPS_AGE_SSH_PRIVATE_KEY_FILE": "/dev/null",
    }


def decrypt(root: Path, identity: Path, document: Path) -> dict:
    return json.loads(
        run(
            [
                "sops",
                "--decrypt",
                "--output-type",
                "json",
                str(document),
            ],
            env=identity_environment(root, identity),
        )
    )


def reject_identity(root: Path, identity: Path, document: Path) -> None:
    result = subprocess.run(
        [
            "sops",
            "--decrypt",
            "--output-type",
            "json",
            str(document),
        ],
        env=identity_environment(root, identity),
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=60,
    )
    assert result.returncode != 0


def recipient(public_key: Path) -> str:
    return run(["ssh-to-age", "-i", str(public_key)]).decode().strip()


def encrypt(document: Path, payload: dict, recipients: list[str]) -> None:
    assert len(recipients) == len(set(recipients))
    ciphertext = run(
        [
            "sops",
            "--encrypt",
            "--age",
            ",".join(recipients),
            "--input-type",
            "json",
            "--output-type",
            "json",
            "/dev/stdin",
        ],
        input=json.dumps(payload).encode(),
    )
    temporary = document.with_suffix(document.suffix + ".new")
    temporary.write_bytes(ciphertext)
    os.replace(temporary, document)


# @cc [owner:ghuntley,label:verification] environment-render-no-cli-values
# Drawn secret values MUST reach the guest only through private files, never
# through command-line arguments (which would land in the systemd journal and
# the process table). The environment file MUST come from the real module
# renderer and the check MUST run inside a real systemd EnvironmentFile unit.
def verify_environment(document: Path, module_path: Path) -> None:
    spec = importlib.util.spec_from_file_location("preparation", str(module_path))
    if spec is None or spec.loader is None:
        raise RuntimeError("preparation helper unavailable")
    module: types.ModuleType = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    expected: dict[str, str] = json.loads(document.read_text())
    target = document.parent / "environment"
    target.write_bytes(
        module.render(expected, {"format": "environment", "secrets": list(expected)})
    )
    run(
        [
            "systemd-run",
            "--quiet",
            "--wait",
            "--collect",
            "--unit=overalls-hegel-custody-verify",
            "--property=EnvironmentFile=" + str(target),
            "--property=StandardOutput=null",
            "--property=StandardError=null",
            sys.executable,
            __file__,
            "assert-env",
            str(document),
        ],
        timeout=180,
    )


def assert_environment(document: Path) -> None:
    expected: dict[str, str] = json.loads(document.read_text())
    # Value-free check: mismatch reports the assertion, never the values.
    assert all(os.environ.get(name) == value for name, value in expected.items())


# @cc [owner:ghuntley,label:verification] recipient-rotation-uses-recovery
# Rotation/replacement MUST recover the existing ciphertext with only the operator identity,
# verify new host decryption before retiring the old recipient, and reject old-host access
# afterward. Re-encryption MUST preserve the recovered payload; private material stays local.
def rotate_host(root: Path, action: str) -> None:
    host = Path("/etc/ssh/ssh_host_ed25519_key")
    document = root / "marshall.enc.json"
    operator = root / "recovery.age"
    recovery = recipient(root / "recovery.ssh.pub")
    payload = decrypt(root, operator, document)
    if action == "stage-host":
        run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / "next-host.ssh")])
        for source, target in [
            (host, root / "retired-host.age"),
            (root / "next-host.ssh", root / "next-host.age"),
        ]:
            run(["ssh-to-age", "-private-key", "-i", str(source), "-o", str(target)])
        encrypt(
            document,
            payload,
            [recipient(host.with_suffix(".pub")), recipient(root / "next-host.ssh.pub"), recovery],
        )
        assert decrypt(root, root / "retired-host.age", document) == payload
        assert decrypt(root, root / "next-host.age", document) == payload
    elif action == "install-host":
        assert decrypt(root, root / "next-host.age", document) == payload
        for source, target, mode in [
            (root / "next-host.ssh", host, 0o600),
            (root / "next-host.ssh.pub", host.with_suffix(".pub"), 0o644),
        ]:
            temporary = target.with_suffix(target.suffix + ".fixture-new")
            with temporary.open("xb") as file:
                file.write(source.read_bytes())
            temporary.chmod(mode)
            os.replace(temporary, target)
    elif action == "retire-host":
        assert host.with_suffix(".pub").read_bytes() == (root / "next-host.ssh.pub").read_bytes()
        encrypt(document, payload, [recipient(host.with_suffix(".pub")), recovery])
        reject_identity(root, root / "retired-host.age", document)
        assert decrypt(root, root / "next-host.age", document) == payload
    elif action == "replace-host":
        document = root / "replacement.enc.json"
        encrypt(document, payload, [recipient(root / "replacement.pub"), recovery])
        reject_identity(root, root / "next-host.age", document)
    else:
        raise ValueError("unknown rotation stage")
    assert decrypt(root, operator, document) == payload


# @cc [owner:ghuntley,label:verification] sealed-fixture-no-private-output
# Synthetic SSH keys and application secrets MUST stay in the test machine's
# private runtime files. Only encrypted documents and public SSH keys may leave it.
def main() -> None:
    os.umask(0o077)
    root = Path("/run/overalls-test-sealed")
    root.mkdir(mode=0o700, exist_ok=True)
    if sys.argv[1] == "verify":
        verify_environment(Path(sys.argv[2]), Path(sys.argv[3]))
        return
    if sys.argv[1] == "assert-env":
        assert_environment(Path(sys.argv[2]))
        return
    if sys.argv[1] in ("stage-host", "install-host", "retire-host", "replace-host"):
        rotate_host(root, sys.argv[1])
        return
    if sys.argv[1] == "verify-replacement":
        identity = root / "verification.age"
        try:
            run(
                [
                    "ssh-to-age",
                    "-private-key",
                    "-i",
                    "/etc/ssh/ssh_host_ed25519_key",
                    "-o",
                    str(identity),
                ]
            )
            restored = decrypt(root, identity, root / "marshall.enc.json")["overalls-marshall"][
                "production"
            ]
            selected = {
                "DATABASE_URL",
                "MARSHALL_CLOAK_KEYS",
                "SECRET_KEY_BASE",
                "TOKEN_SIGNING_SECRET",
                "MARSHALL_SMTP_HOST",
                "MARSHALL_SMTP_USERNAME",
                "MARSHALL_SMTP_PASSWORD",
                "MARSHALL_SMTP_CA_CERTFILE",
                "MARSHALL_MAIL_FROM",
            }
            published = dict(
                item.split("=", 1)
                for item in shlex.split(
                    Path("/run/overalls-secrets/marshall/environment").read_text()
                )
            )
            assert published == {name: restored[name] for name in selected}
            assert (
                Path("/run/overalls-secrets/marshall/serper.key").read_text()
                == restored["SERPER_API_KEY"]
            )
            journal = run(
                ["journalctl", "--no-pager", "--output=cat", "-u", "overalls-secrets-marshall"]
            )
            private = {
                "DATABASE_URL",
                "MARSHALL_CLOAK_KEYS",
                "SECRET_KEY_BASE",
                "TOKEN_SIGNING_SECRET",
                "MARSHALL_SMTP_PASSWORD",
                "SERPER_API_KEY",
            }
            assert not any(restored[name].encode() in journal for name in private)
            assert b"AGE-SECRET-KEY-" not in journal and b"BEGIN OPENSSH PRIVATE KEY" not in journal
        finally:
            identity.unlink(missing_ok=True)
        return
    values = dict(
        item.split("=", 1)
        for item in shlex.split(Path("/run/overalls-test/marshall.env").read_text())
    )
    values["SERPER_API_KEY"] = "synthetic-serper-placeholder"
    if sys.argv[1] in ("verify-running", "verify-previous"):
        pid = (
            run(["systemctl", "show", "--property=MainPID", "--value", "marshall-primary.service"])
            .decode()
            .strip()
        )
        entries = Path("/proc", pid, "environ").read_bytes().split(b"\0")
        expected = (
            (root / "previous-password").read_text()
            if sys.argv[1] == "verify-previous"
            else values["MARSHALL_SMTP_PASSWORD"]
        )
        assert ("MARSHALL_SMTP_PASSWORD=" + expected).encode() in entries
        return
    if sys.argv[1] == "check-journal":
        journal = run(
            [
                "journalctl",
                "--no-pager",
                "--output=cat",
                "-u",
                "overalls-secrets-marshall",
                "-u",
                "marshall-primary",
            ]
        )
        private = [
            values[name]
            for name in (
                "DATABASE_URL",
                "MARSHALL_CLOAK_KEYS",
                "SECRET_KEY_BASE",
                "TOKEN_SIGNING_SECRET",
                "MARSHALL_SMTP_PASSWORD",
                "SERPER_API_KEY",
            )
        ]
        previous = root / "previous-password"
        private += [
            *([previous.read_text()] if previous.exists() else []),
            "AGE-SECRET-KEY-",
            "BEGIN OPENSSH PRIVATE KEY",
        ]
        assert not any(value.encode() in journal for value in private)
        return
    if sys.argv[1] == "rotate":
        (root / "previous-password").write_text(values["MARSHALL_SMTP_PASSWORD"])
        values["MARSHALL_SMTP_PASSWORD"] = secrets.token_hex(32)
        Path("/run/overalls-test/marshall.env").write_text(
            "".join(
                f"{name}='{value}'\n" for name, value in values.items() if name != "SERPER_API_KEY"
            )
        )
    if sys.argv[1] == "recover":
        environment = {
            "PATH": os.environ["PATH"],
            "XDG_CONFIG_HOME": str(root),
            "SOPS_AGE_KEY_FILE": str(root / "recovery.age"),
            "SOPS_AGE_SSH_PRIVATE_KEY_FILE": "/dev/null",
        }
        restored = json.loads(
            run(
                ["sops", "--decrypt", "--output-type", "json", str(root / "marshall.enc.json")],
                env=environment,
            )
        )
        assert restored["overalls-marshall"]["production"] == values
        return
    if not (root / "recovery.ssh").exists():
        run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-f", str(root / "recovery.ssh")])
        run(
            [
                "ssh-to-age",
                "-private-key",
                "-i",
                str(root / "recovery.ssh"),
                "-o",
                str(root / "recovery.age"),
            ]
        )
    host = run(["ssh-to-age", "-i", "/etc/ssh/ssh_host_ed25519_key.pub"]).decode().strip()
    recovery = run(["ssh-to-age", "-i", str(root / "recovery.ssh.pub")]).decode().strip()
    assert host != recovery
    if sys.argv[1] == "missing":
        del values["DATABASE_URL"]
    ciphertext = run(
        [
            "sops",
            "--encrypt",
            "--age",
            host + "," + recovery,
            "--input-type",
            "json",
            "--output-type",
            "json",
            "/dev/stdin",
        ],
        input=json.dumps(
            {
                "overalls-marshall": {"production": values},
                "overalls-shared": {
                    "production": {"FIXTURE_TOKEN": values["TOKEN_SIGNING_SECRET"]}
                },
            }
        ).encode(),
    )
    temporary = root / "marshall.enc.json.new"
    temporary.write_bytes(ciphertext)
    os.replace(temporary, root / "marshall.enc.json")


if __name__ == "__main__":
    try:
        main()
    except Exception:
        print("Synthetic secret fixture failed", file=sys.stderr)
        sys.exit(1)
