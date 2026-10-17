"""Verify and identify every foreign executable installed by lyra.native."""

import hashlib
import json
import re
import struct
import subprocess
import sys
from pathlib import Path
from typing import TypedDict

MAX_BINARY = 100 * 1024 * 1024
TARGETS = ("x86_64-unknown-freebsd", "x86_64-unknown-illumos")
BINARIES = (
    "overalls-native-bootstrap",
    "overalls-native-grow-root",
    "overalls-native-readinessd",
    "overalls-native-trustd",
    "overalls-native-workspaced",
    "overalls-native-kernel-probed",
    "overalls-native-agentd",
    "overalls-native-flushd",
    "overalls-ssh-authorize",
    "overalls-host-certificate",
)
INTERPRETERS = {
    "x86_64-unknown-freebsd": "/libexec/ld-elf.so.1",
    "x86_64-unknown-illumos": "/usr/lib/amd64/ld.so.1",
}
NEEDED_LIBRARIES = {
    "x86_64-unknown-freebsd": {"libc.so.7", "libthr.so.3"},
    "x86_64-unknown-illumos": {
        "libc.so.1",
        "libgcc_s.so.1",
        "libpthread.so.1",
        "librt.so.1",
        "libsendfile.so.1",
        "libsocket.so.1",
        "libumem.so.1",
    },
}


class Artifact(TypedDict):
    path: str
    sha256: str
    bytes: int
    target: str
    interpreter: str
    needed: list[str]


class BuildMetadata(TypedDict):
    cargo_lock_sha256: str
    illumos_sdk_nar_hash: str
    clang_version: str
    clang_patch_sha256: str
    binutils_version: str
    rust_version: str


def build_metadata(path: Path) -> BuildMetadata:
    raw: object = json.loads(path.read_text())
    if not isinstance(raw, dict) or set(raw) != set(BuildMetadata.__annotations__):
        raise ValueError("invalid native toolchain metadata")
    fields: dict[str, str] = {}
    for key, value in raw.items():
        if not isinstance(key, str) or not isinstance(value, str) or not value:
            raise ValueError("invalid native toolchain field")
        fields[key] = value
    return BuildMetadata(
        cargo_lock_sha256=fields["cargo_lock_sha256"],
        illumos_sdk_nar_hash=fields["illumos_sdk_nar_hash"],
        clang_version=fields["clang_version"],
        clang_patch_sha256=fields["clang_patch_sha256"],
        binutils_version=fields["binutils_version"],
        rust_version=fields["rust_version"],
    )


def inspect_binary(path: Path, target: str, readelf: str) -> Artifact:
    """@cc [owner:ghuntley,label:build;security] native-linked-agent-identity
    Every native agent MUST be a bounded ELF64 AMD64 executable with its target's
    guest interpreter and a non-executable stack. An unreviewed shared library,
    Linux interpreter or runtime search path MUST refuse manifest generation.
    """
    with path.open("rb") as source:
        data = source.read(MAX_BINARY + 1)
    if (
        len(data) < 64
        or len(data) > MAX_BINARY
        or data[:7] != b"\x7fELF\x02\x01\x01"
        or struct.unpack_from("<H", data, 16)[0] not in (2, 3)
        or struct.unpack_from("<H", data, 18)[0] != 62
    ):
        raise ValueError("native binary must be a bounded ELF64 AMD64 executable")
    report = subprocess.run(
        [readelf, "--wide", "--program-headers", "--dynamic", str(path)],
        check=True,
        capture_output=True,
        text=True,
        timeout=30,
        env={"LC_ALL": "C"},
    ).stdout
    interpreters = re.findall(r"\[Requesting program interpreter: ([^\]]+)\]", report)
    expected = INTERPRETERS[target]
    if interpreters != [expected]:
        raise ValueError("native binary has an unexpected interpreter")
    if re.search(r"\((?:RPATH|RUNPATH)\)", report) or "/nix/store/" in report:
        raise ValueError("native binary has a runtime search path")
    stacks = [line.split() for line in report.splitlines() if "GNU_STACK" in line]
    if len(stacks) != 1 or stacks[0][6:-1] != ["RW"]:
        raise ValueError("native binary has an executable or missing stack declaration")
    needed = re.findall(r"\(NEEDED\).*Shared library: \[([^\]]+)\]", report)
    if not needed or len(needed) != len(set(needed)):
        raise ValueError("native binary has missing or duplicate runtime dependencies")
    if not set(needed).issubset(NEEDED_LIBRARIES[target]):
        raise ValueError("native binary has an unreviewed runtime dependency")
    return Artifact(
        path="/bin/" + path.name,
        sha256=hashlib.sha256(data).hexdigest(),
        bytes=len(data),
        target=target,
        interpreter=expected,
        needed=needed,
    )


def assemble(
    root: Path, metadata: Path, readelf: str, binaries: tuple[str, ...] = BINARIES
) -> None:
    """@cc [owner:ghuntley,label:build;verification] native-agent-manifest-completeness
    The package MUST contain exactly the expected native/helper binaries: twenty
    for Lyra, or one terminal daemon or transport probe for each target when selected.
    Its manifest MUST identify each executable's exact bytes and toolchain inputs
    and MUST retain native_admission=false regardless of successful cross-linking.
    """
    expected = {f"{target}-{binary}" for target in TARGETS for binary in binaries}
    if {path.name for path in (root / "bin").iterdir()} != expected:
        raise ValueError("native package must contain exactly its expected binaries")
    artifacts = {
        f"{target}-{binary}": inspect_binary(root / "bin" / f"{target}-{binary}", target, readelf)
        for target in TARGETS
        for binary in binaries
    }
    manifest = {
        "version": "0.1.0",
        "native_admission": False,
        "build": build_metadata(metadata),
        "artifacts": artifacts,
    }
    (root / "manifest.json").write_text(json.dumps(manifest, sort_keys=True) + "\n")


def main() -> None:
    if len(sys.argv) not in (4, 5):
        raise ValueError("expected native package root, metadata, readelf and optional mode")
    mode = sys.argv[4] if len(sys.argv) == 5 else "--agents"
    variants = {
        "--agents": BINARIES,
        "--terminald": ("lilly-terminald",),
        "--probes": ("overalls-native-transport-probe",),
    }
    if mode not in variants:
        raise ValueError("invalid native package mode")
    binaries = variants[mode]
    assemble(Path(sys.argv[1]), Path(sys.argv[2]), sys.argv[3], binaries)


if __name__ == "__main__":
    main()
