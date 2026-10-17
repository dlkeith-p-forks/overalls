"""Root-only SecretSpec/SOPS resolution and atomic runtime bundle publication."""

import contextlib
import ctypes
import grp
import hashlib
import json
import os
import re
import selectors
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
from pathlib import Path
from typing import TypedDict

MAX_FILE_BYTES = 65536
MAX_RESOLUTION_BYTES = 4 * 1024 * 1024


class Output(TypedDict):
    format: str
    secrets: list[str]


class Configuration(TypedDict):
    hostKey: str
    runtime: str
    encryptedFile: str
    group: str
    outputs: dict[str, Output]
    destination: str
    manifest: str
    toolPath: str
    sshToAge: str
    secretspec: str


def string(value: object) -> str:
    if not isinstance(value, str):
        raise ValueError("expected string")
    return value


def strings(value: object) -> list[str]:
    if not isinstance(value, list):
        raise ValueError("expected array")
    return [string(item) for item in value]


def object_value(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError("expected object")
    return value


def output_value(raw: object) -> Output:
    row = object_value(raw)
    return Output(format=string(row["format"]), secrets=strings(row["secrets"]))


def configuration_value(raw: object) -> Configuration:
    row = object_value(raw)
    outputs_row = object_value(row["outputs"])
    return Configuration(
        hostKey=string(row["hostKey"]),
        runtime=string(row["runtime"]),
        encryptedFile=string(row["encryptedFile"]),
        group=string(row["group"]),
        outputs={name: output_value(value) for name, value in outputs_row.items()},
        destination=string(row["destination"]),
        manifest=string(row["manifest"]),
        toolPath=string(row["toolPath"]),
        sshToAge=string(row["sshToAge"]),
        secretspec=string(row["secretspec"]),
    )


def private_file(path: Path) -> None:
    info = path.lstat()
    if (
        not stat.S_ISREG(info.st_mode)
        or info.st_uid != 0
        or stat.S_IMODE(info.st_mode) != 0o600
        or info.st_nlink != 1
        or not 0 < info.st_size <= MAX_FILE_BYTES
    ):
        raise ValueError("invalid private file")
    safe_directory(path.parent)


def safe_directory(path: Path) -> None:
    if not path.is_absolute() or str(path) != os.path.normpath(path):
        raise ValueError("invalid directory")
    for parent in [path, *path.parents]:
        info = parent.lstat()
        if (
            not stat.S_ISDIR(info.st_mode)
            or info.st_uid != 0
            or (info.st_mode & 0o022 and not info.st_mode & stat.S_ISVTX)
        ):
            raise ValueError("untrusted directory")


# @cc [owner:ghuntley,label:security] secret-resolver-bounded-diagnostics
# Subprocess outputs MUST remain private and bounded in memory. Timeout or
# excessive output MUST terminate the process group; diagnostics MUST be fixed.
def capture(arguments: list[str], environment: dict[str, str], timeout: int = 60) -> bytes:
    with subprocess.Popen(
        arguments,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env=environment,
        start_new_session=True,
    ) as process:
        assert process.stdout is not None
        deadline = time.monotonic() + timeout
        output = bytearray()
        try:
            with selectors.DefaultSelector() as selector:
                selector.register(process.stdout, selectors.EVENT_READ)
                while True:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0 or not selector.select(remaining):
                        raise ValueError("resolver timed out")
                    chunk = os.read(process.stdout.fileno(), 65536)
                    if not chunk:
                        break
                    if len(output) + len(chunk) > MAX_RESOLUTION_BYTES:
                        raise ValueError("resolver output too large")
                    output.extend(chunk)
            remaining = deadline - time.monotonic()
            if remaining <= 0 or process.wait(timeout=remaining) != 0:
                raise ValueError("resolver failed")
            return bytes(output)
        except BaseException:
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            process.wait()
            raise


def render(values: dict[str, str], output: Output) -> bytes:
    names = output["secrets"]
    if not names or not all(re.fullmatch(r"[A-Z_][A-Z0-9_]*", name) for name in names):
        raise ValueError("invalid selection")
    selected = {name: values[name] for name in names}
    if any(not isinstance(value, str) or not value or "\0" in value for value in selected.values()):
        raise ValueError("invalid secret")
    if output["format"] == "raw" and len(names) == 1:
        result = selected[names[0]]
    elif output["format"] == "environment":
        if any(
            ord(character) in (0xFEFF,)
            or 0xD800 <= ord(character) <= 0xDFFF
            or 0xFDD0 <= ord(character) <= 0xFDEF
            or ord(character) & 0xFFFF in (0xFFFE, 0xFFFF)
            for value in selected.values()
            for character in value
        ):
            raise ValueError("invalid environment character")
        # systemd EnvironmentFile double quotes allow literal newlines and do
        # not expand dollars. Escape backslashes and quotes; never source this
        # format in a shell.
        result = "".join(
            name + '="' + value.replace("\\", "\\\\").replace('"', '\\"') + '"\n'
            for name, value in selected.items()
        )
    else:
        raise ValueError("invalid format")
    encoded = result.encode("utf-8")
    if len(encoded) > MAX_FILE_BYTES:
        raise ValueError("secret file too large")
    return encoded


def exchange_directories(staging: Path, destination: Path) -> None:
    libc = ctypes.CDLL(None, use_errno=True)
    rename = libc.renameat2
    rename.argtypes = [ctypes.c_int, ctypes.c_char_p, ctypes.c_int, ctypes.c_char_p, ctypes.c_uint]
    rename.restype = ctypes.c_int
    # AT_FDCWD, RENAME_EXCHANGE: replace the entire directory without a
    # symlink or an interval in which only some credentials are available.
    if rename(-100, os.fsencode(staging), -100, os.fsencode(destination), 2) != 0:
        raise OSError(ctypes.get_errno(), "atomic publication failed")


def pending_prefix(destination: Path) -> str:
    # Fixed-length digest prevents one bundle name matching another's prefix.
    return ".pending-" + hashlib.sha256(destination.name.encode()).hexdigest() + "-"


def cleanup(configuration: Configuration) -> None:
    if os.geteuid() != 0:
        raise ValueError("root required")
    runtime = Path(configuration["runtime"])
    safe_directory(runtime)
    (runtime / "identity").unlink(missing_ok=True)
    destination = Path(configuration["destination"])
    safe_directory(destination.parent)
    for pending in destination.parent.glob(pending_prefix(destination) + "*"):
        safe_directory(pending)
        shutil.rmtree(pending)


def sync_directory(path: Path) -> None:
    descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


# @cc [owner:ghuntley,label:recovery] secret-publication-complete-or-previous
# Publication MUST prepare every file before the namespace change, retain the
# previous bundle on validation failure, and preserve canonical nonsymlink paths.
# Durable publication MUST fsync the new directory and its namespace change.
def publish(
    destination: Path, contents: dict[str, bytes], group: str, *, durable: bool = False
) -> None:
    safe_directory(destination.parent)
    group_id = grp.getgrnam(group).gr_gid
    directory_mode, file_mode = (0o700, 0o600) if group_id == 0 else (0o750, 0o640)
    if os.path.lexists(destination):
        safe_directory(destination)
        current = destination.lstat()
        if current.st_gid != group_id or stat.S_IMODE(current.st_mode) != directory_mode:
            raise ValueError("existing bundle ownership mismatch")
    staging = Path(tempfile.mkdtemp(prefix=pending_prefix(destination), dir=destination.parent))
    try:
        for name, encoded in contents.items():
            if not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9_.-]{0,127}", name):
                raise ValueError("invalid output name")
            with (staging / name).open("xb") as stream:
                os.fchmod(stream.fileno(), file_mode)
                os.fchown(stream.fileno(), 0, group_id)
                stream.write(encoded)
                stream.flush()
                os.fsync(stream.fileno())
        os.chown(staging, 0, group_id)
        os.chmod(staging, directory_mode)
        if durable:
            sync_directory(staging)
        if os.path.lexists(destination):
            exchange_directories(staging, destination)
        else:
            os.replace(staging, destination)
        if durable:
            sync_directory(destination.parent)
    finally:
        if staging.exists():
            shutil.rmtree(staging)


def descriptor_id(configuration: Configuration) -> str:
    return hashlib.sha256(
        json.dumps(configuration, sort_keys=True, separators=(",", ":")).encode()
    ).hexdigest()


# @cc [owner:ghuntley,label:security] staged-secrets-bound-to-descriptor
# A handoff MUST match the complete secret descriptor and contain only private
# files selected by that descriptor. Invalid matching staging MUST fail closed;
# it MUST NOT silently resolve different values after migration used staging.
def staged_contents(configuration: Configuration) -> dict[str, bytes] | None:
    handoff = Path("/run/overalls-auto-update/handoff.json")
    if not os.path.lexists(handoff):
        return None
    private_file(handoff)
    entries: object = json.loads(handoff.read_bytes())
    if not isinstance(entries, dict):
        raise AttributeError("invalid handoff")
    selected = entries.get(descriptor_id(configuration))
    if selected is None:
        return None
    if not isinstance(selected, str):
        raise TypeError("invalid staged selection")
    directory = Path(selected)
    safe_directory(directory)
    if set(os.listdir(directory)) != set(configuration["outputs"]):
        raise ValueError("invalid staged selection")
    contents: dict[str, bytes] = {}
    for name in configuration["outputs"]:
        path = directory / name
        private_file(path)
        contents[name] = path.read_bytes()
    return contents


# @cc [owner:ghuntley,label:recovery] resolution-does-not-publish
# resolve MUST return a complete validated selection without modifying consumer
# bundles. Temporary derived identities MUST be removed on success and failure.
def resolve(configuration: Configuration) -> dict[str, bytes]:
    if os.geteuid() != 0:
        raise ValueError("root required")
    os.umask(0o077)
    runtime = Path(configuration["runtime"])
    safe_directory(runtime)
    cleanup(configuration)
    key = Path(configuration["hostKey"])
    private_file(key)
    identity = runtime / "identity"
    environment = {
        "PATH": configuration["toolPath"],
        "XDG_CONFIG_HOME": str(runtime / "config"),
        "XDG_CACHE_HOME": str(runtime / "cache"),
        "XDG_DATA_HOME": str(runtime / "data"),
        "SOPS_AGE_KEY_FILE": str(identity),
        "SOPS_AGE_SSH_PRIVATE_KEY_FILE": "/dev/null",
    }
    try:
        with identity.open("xb") as stream:
            stream.write(
                capture([configuration["sshToAge"], "-private-key", "-i", str(key)], environment)
            )
        private_file(identity)
        encrypted = Path(configuration["encryptedFile"])
        safe_directory(encrypted.parent)
        encrypted_info = encrypted.stat()
        if (
            not stat.S_ISREG(encrypted_info.st_mode)
            or encrypted_info.st_uid != 0
            or encrypted_info.st_mode & 0o022
            or encrypted_info.st_size > 16 * 1024 * 1024
        ):
            raise ValueError("invalid encrypted document")
        resolved: object = json.loads(
            capture(
                [
                    configuration["secretspec"],
                    "export",
                    "--file",
                    configuration["manifest"],
                    "--provider",
                    "sops://" + str(encrypted),
                    "--profile",
                    "production",
                    "--format",
                    "json",
                ],
                environment,
            )
        )
        expected = {
            name for output in configuration["outputs"].values() for name in output["secrets"]
        }
        if not isinstance(resolved, dict) or set(resolved) != expected:
            raise ValueError("invalid resolved selection")
        return {name: render(resolved, output) for name, output in configuration["outputs"].items()}
    finally:
        identity.unlink(missing_ok=True)


def prepare(configuration: Configuration) -> None:
    contents = staged_contents(configuration)
    if contents is None:
        contents = resolve(configuration)
    publish(Path(configuration["destination"]), contents, configuration["group"])


if __name__ == "__main__":
    try:
        cleaning = sys.argv[1] == "--cleanup"
        configuration = configuration_value(
            json.loads(Path(sys.argv[2 if cleaning else 1]).read_text())
        )
        (cleanup if cleaning else prepare)(configuration)
    except Exception:
        print('{"event":"secrets.preparation_failed","severity":"error"}', file=sys.stderr)
        sys.exit(1)
    if not cleaning:
        print('{"event":"secrets.prepared","severity":"info"}')
