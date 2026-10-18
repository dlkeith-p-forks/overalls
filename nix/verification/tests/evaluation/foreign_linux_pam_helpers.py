"""Check the exact PAM installer in a disposable root and private mount namespace."""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import Final

INSTALLER: Final = Path("@installer@")
PAM: Final = Path("@pam@")
CHROOT: Final = "@chroot@"
MOUNT: Final = "@mount@"
UNSHARE: Final = "@unshare@"
PYTHON: Final = Path("@python@")
PROBE: Final = Path("@probe@")
HELPER: Final = "run/wrappers/bin/unix_chkpwd"


def command(arguments: list[str]) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(arguments, check=False, capture_output=True, timeout=20)


def guarded(root: Path) -> None:
    if (
        root.parent != Path("/tmp")
        or not root.name.startswith("overalls-pam-helper-proof-")
        or root.resolve(strict=True) != root
        or root.is_symlink()
        or root.stat().st_uid != 0
    ):
        raise ValueError("unsafe disposable root")


def reset(root: Path) -> None:
    runtime = root / "run"
    if runtime.is_symlink() or (runtime.exists() and not runtime.is_dir()):
        runtime.unlink()
    elif runtime.exists():
        shutil.rmtree(runtime)
    runtime.mkdir(mode=0o755)
    runtime.chmod(0o755)


def invoke(root: Path, arguments: tuple[str, ...] = (), *, nonroot: bool = False) -> int:
    options = ["--userspec=65534:65534"] if nonroot else []
    result = command([CHROOT, *options, str(root), str(INSTALLER), *arguments])
    return result.returncode


def account_probe(root: Path) -> int:
    result = command([CHROOT, str(root), str(PYTHON), "/probe.py"])
    if result.returncode != 0:
        raise ValueError("synthetic account probe failed")
    value: object = json.loads(result.stdout)
    if not isinstance(value, dict) or set(value) != {"status"}:
        raise ValueError("invalid account probe receipt")
    status: object = value["status"]
    if type(status) is not int or not 0 <= status <= 31:
        raise ValueError("invalid account probe status")
    return status


def pam_proof(root: Path) -> dict[str, int | bool]:
    """@cc [owner:ghuntley,label:verification;security] foreign-linux-pam-nosuid-account
    The root-caller account probe MUST reproduce missing-helper PAM9, succeed
    with the fixed helper even on nosuid runtime storage, and preserve expired,
    password-change and unknown-account refusals. The probe MUST NOT establish
    nonroot setuid elevation, password authentication or SSH session acceptance.
    """
    reset(root)
    etc = root / "etc"
    (etc / "pam.d").mkdir(parents=True)
    (etc / "nsswitch.conf").write_text("passwd: files\ngroup: files\nshadow: files\n")
    (etc / "passwd").write_text("fixture:x:200001:200001::/home/fixture:/bin/bash\n")
    shadow = etc / "shadow"
    shadow.write_text("fixture:!:20000:0:99999:7:::\n")
    shadow.chmod(0o600)
    (etc / "pam.d/sshd").write_text(
        "account required " + str(PAM / "lib/security/pam_unix.so") + "\n"
    )
    shutil.copyfile(PROBE, root / "probe.py")
    missing = account_probe(root)
    if missing != 9:
        raise ValueError("missing-helper account failure was not reproduced")
    runtime = root / "run"
    if (
        command(
            [MOUNT, "-t", "tmpfs", "-o", "nosuid,nodev,mode=0755", "tmpfs", str(runtime)]
        ).returncode
        != 0
    ):
        raise ValueError("isolated nosuid runtime mount failed")
    try:
        if not os.statvfs(runtime).f_flag & os.ST_NOSUID:
            raise ValueError("fixture runtime is not nosuid")
        if invoke(root) != 0:
            raise ValueError("nosuid runtime installation failed")
        valid = account_probe(root)
        shadow.write_text("fixture:!:20000:0:99999:7::1:\n")
        expired = account_probe(root)
        shadow.write_text("fixture:!:0:0:99999:7:::\n")
        change_required = account_probe(root)
        (etc / "passwd").write_text("")
        unknown = account_probe(root)
        if (valid, expired, change_required, unknown) != (0, 13, 12, 10):
            raise ValueError("PAM account success or refusal differs")
        return {
            "missing_helper": missing,
            "valid_account": valid,
            "expired_account": expired,
            "password_change_required": change_required,
            "unknown_account": unknown,
            "root_caller_on_nosuid_runtime": True,
        }
    finally:
        umount = str(Path(MOUNT).with_name("umount"))
        if command([umount, str(runtime)]).returncode != 0:
            raise ValueError("isolated nosuid runtime retirement failed")


def main() -> None:
    """@cc [owner:ghuntley,label:verification;security] foreign-linux-disposable-pam-helper-runtime
    Runtime checks MUST use only a disposable chroot and private mount namespace,
    preserve the immutable source and host runtime, and emit closed test results.
    """
    if os.getresuid() != (0, 0, 0):
        raise ValueError("root identity required for isolated setuid-copy proof")
    if len(sys.argv) == 1:
        child = command(
            [UNSHARE, "--mount", "--propagation=private", str(PYTHON), __file__, "--inside"]
        )
        if child.returncode != 0:
            # All child inputs are bounded synthetic fixtures and immutable
            # package paths; preserve their failure traceback in the CI log.
            sys.stderr.buffer.write(child.stderr)
            raise ValueError("isolated synthetic runtime proof failed")
        value: object = json.loads(child.stdout)
        if not isinstance(value, dict):
            raise ValueError("invalid runtime receipt")
        print(json.dumps(value, sort_keys=True))
        return
    if sys.argv[1:] != ["--inside"]:
        raise ValueError("invalid diagnostic mode")
    root = Path(tempfile.mkdtemp(prefix="overalls-pam-helper-proof-", dir="/tmp"))
    mounted = False
    source_overlay = False
    source_target = root / str(PAM / "bin/unix_chkpwd").lstrip("/")
    try:
        guarded(root)
        root.chmod(0o755)
        (root / "nix/store").mkdir(parents=True, mode=0o755)
        for arguments in (
            [MOUNT, "--bind", "/nix/store", str(root / "nix/store")],
            [MOUNT, "-o", "remount,bind,ro", str(root / "nix/store")],
        ):
            if command(arguments).returncode != 0:
                raise ValueError("read-only Nix bind failed")
            mounted = True
        source = PAM / "bin/unix_chkpwd"
        source_metadata = source.lstat()
        before = hashlib.sha256(source.read_bytes()).hexdigest()
        if (
            not stat.S_ISREG(source_metadata.st_mode)
            or stat.S_IMODE(source_metadata.st_mode) != 0o555
        ):
            raise ValueError("immutable source has unexpected permissions")
        # vmTools projects host-store ownership to nobody over virtiofs. Keep
        # the real installer guard and replace only its source inode inside
        # this private fixture with an exact root-owned mode-0555 copy.
        if (source_metadata.st_uid, source_metadata.st_gid) != (0, 0):
            scratch_source = root / "pinned-unix-chkpwd"
            scratch_source.write_bytes(source.read_bytes())
            scratch_source.chmod(0o555)
            if hashlib.sha256(scratch_source.read_bytes()).hexdigest() != before:
                raise ValueError("fixture source bytes differ from pinned binary")
            if command([MOUNT, "--bind", str(scratch_source), str(source_target)]).returncode != 0:
                raise ValueError("fixture source ownership overlay failed")
            source_overlay = True
            if command([MOUNT, "-o", "remount,bind,ro", str(source_target)]).returncode != 0:
                raise ValueError("fixture source overlay is not read-only")
        reset(root)
        if invoke(root) != 0:
            interpreter = INSTALLER.read_text().splitlines()[0].removeprefix("#!")
            diagnostic = command([CHROOT, str(root), interpreter, "-x", str(INSTALLER)])
            sys.stderr.buffer.write(diagnostic.stderr)
            raise ValueError("fixed installer failed in clean runtime")
        installed = root / HELPER
        metadata = installed.lstat()
        exact = (
            stat.S_ISREG(metadata.st_mode)
            and stat.S_IMODE(metadata.st_mode) == 0o4755
            and (metadata.st_uid, metadata.st_gid) == (0, 0)
            and installed.read_bytes() == source.read_bytes()
        )
        if not exact or invoke(root) != 0 or installed.read_bytes() != source.read_bytes():
            raise ValueError("installed helper identity or repeat installation differs")
        negatives: dict[str, bool] = {}
        for case in (
            "run-symlink",
            "run-mode",
            "wrappers-symlink",
            "wrappers-file",
            "wrappers-owner",
            "bin-symlink",
            "bin-file",
            "helper-symlink",
            "helper-directory",
            "helper-owner",
            "argument",
            "nonroot",
        ):
            reset(root)
            wrappers = root / "run/wrappers"
            binary_directory = wrappers / "bin"
            outside = root / "outside"
            outside.mkdir(exist_ok=True)
            sentinel = outside / "unix_chkpwd"
            sentinel.write_bytes(b"unchanged")
            if case == "run-symlink":
                (root / "run").rmdir()
                (root / "run").symlink_to("/outside")
            elif case == "run-mode":
                (root / "run").chmod(0o777)
            elif case == "wrappers-symlink":
                wrappers.symlink_to("/outside")
            elif case == "wrappers-file":
                wrappers.write_bytes(b"unchanged")
            elif case == "wrappers-owner":
                wrappers.mkdir(mode=0o755)
                os.chown(wrappers, 65534, 65534)
            elif case in ("bin-symlink", "bin-file"):
                wrappers.mkdir(mode=0o755)
                if case == "bin-symlink":
                    binary_directory.symlink_to("/outside")
                else:
                    binary_directory.write_bytes(b"unchanged")
            elif case.startswith("helper-"):
                binary_directory.mkdir(parents=True, mode=0o755)
                if case == "helper-symlink":
                    installed.symlink_to("/outside/unix_chkpwd")
                elif case == "helper-directory":
                    installed.mkdir(mode=0o755)
                else:
                    installed.write_bytes(b"unchanged")
                    os.chown(installed, 65534, 65534)
            arguments = ("unexpected",) if case == "argument" else ()
            refused = invoke(root, arguments, nonroot=case == "nonroot") != 0
            negatives[case] = refused and sentinel.read_bytes() == b"unchanged"
        if not all(negatives.values()):
            raise ValueError("unsafe runtime fixture was accepted")
        pam_accounts = pam_proof(root)
        if hashlib.sha256(source.read_bytes()).hexdigest() != before:
            raise ValueError("immutable helper source changed")
        print(
            json.dumps(
                {
                    "installer": str(INSTALLER),
                    "installer_sha256": hashlib.sha256(INSTALLER.read_bytes()).hexdigest(),
                    "source": str(source),
                    "source_sha256": before,
                    "source_mode": "0555",
                    "store_projection_uid": source_metadata.st_uid,
                    "store_projection_gid": source_metadata.st_gid,
                    "byte_identical_root_source_overlay": source_overlay,
                    "runtime_mode": "04755",
                    "regular_root_owned_exact_copy": exact,
                    "repeat_installation_passed": True,
                    "negative_cases": negatives,
                    "pam_account_status": pam_accounts,
                    "private_read_only_nix_namespace": True,
                    "scope": "isolated installer execution; no live guest or SSH acceptance",
                },
                sort_keys=True,
            )
        )
    finally:
        guarded(root)
        umount = str(Path(MOUNT).with_name("umount"))
        if source_overlay and command([umount, str(source_target)]).returncode != 0:
            raise ValueError("isolated source overlay retirement failed")
        if mounted and command([umount, str(root / "nix/store")]).returncode != 0:
            raise ValueError("isolated bind retirement failed")
        shutil.rmtree(root)


if __name__ == "__main__":
    main()
