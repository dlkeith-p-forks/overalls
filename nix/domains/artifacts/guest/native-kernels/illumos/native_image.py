#!/usr/bin/python3
"""Offline, native-only assembly of a separate scratch OmniOS ZFS pool."""

from __future__ import annotations

import base64
import binascii
import hashlib
import json
import os
import re
import shutil
import socket
import stat
import sys
import xml.etree.ElementTree as ET
from dataclasses import dataclass
from pathlib import Path

import native_candidate as kernel

POOL = "overalls_native_candidate"
SOURCE = f"{POOL}/ROOT/omnios-r151050"
TARGET = f"{POOL}/ROOT/overalls-native-candidate"
WORK = Path("/mnt/overalls-native-assembly")
ROOT = WORK / "candidate"
RECEIPT = "etc/overalls/native-image/assembly-receipt.json"
MAX_PAYLOAD = 64 * 1024 * 1024
MAX_MANIFEST = 8 * 1024 * 1024
PREFIXES = {"boot", "etc", "lib", "opt", "usr", "share"}
SUDOERS = "root/etc/sudoers"
TRUST_BASE = "root/etc/overalls/system-ca.pem"
TRUST_DESTINATION = "root/etc/ssl/cacert.pem"
MAX_TRUST_BASE = 1024 * 1024
MAX_TRUST_CERT = 16384
MAX_TRANSIENT = 65536
TRANSIENT_CONFIG = "boot/transient.conf"
CONSOLE_SETTINGS = {
    "etc/system": b"\n* Overalls Firecracker UART nexus.\nset pseudo_isa=1\n",
    "boot/loader.conf.local": (
        b"\n# Overalls Firecracker serial console.\n"
        b'console="ttya"\nos_console="ttya"\nttya-mode="115200,8,n,1,-"\n'
    ),
}
SERVICE_PROFILE = "etc/svc/profile/site/overalls-native-services.xml"
STOCK_SERVICE_MANIFESTS = (
    "lib/svc/manifest/system/cloud-init.xml",
    "lib/svc/manifest/network/ssh.xml",
)
STOCK_SERVICES = (
    "svc:/system/cloud-init:initlocal",
    "svc:/system/cloud-init:init",
    "svc:/system/cloud-init:modules",
    "svc:/system/cloud-init:final",
    "svc:/network/ssh:default",
)
STOCK_NETWORK_FILES = (
    "etc/hostname.vioif0",
    "etc/dhcp.vioif0",
    "etc/dhcp6.vioif0",
    "etc/hostname6.vioif0",
)
NATIVE_SERVICE_MANIFESTS = (
    "lib/svc/manifest/site/overalls-native-growth.xml",
    "lib/svc/manifest/site/overalls-native-bootstrap.xml",
    "lib/svc/manifest/site/overalls-native-agents.xml",
)
NATIVE_SSHD = "usr/sbin/sshd"


@dataclass(frozen=True)
class Entry:
    name: str
    kind: str
    digest: str
    mode: int
    target: str = ""


def check_symlink(name: str, target: str) -> None:
    """@cc [owner:ghuntley,label:security] native-image-link-confinement
    Kit links MUST remain lexically inside the kit. Installed FHS links MUST
    remain inside the guest root and resolve to an allowed FHS prefix; absolute
    installed targets refer to that guest root. Validation MUST NOT follow a
    link through the assembling host's filesystem.
    """
    guest = name.startswith("root/")
    parts = list(Path(name).parent.parts[1:] if guest else Path(name).parent.parts)
    if not target or any(character in target for character in ("\0", "\n", "\r")):
        raise ValueError("invalid payload symlink")
    if target.startswith("/"):
        if not guest:
            raise ValueError("kit symlink must remain inside the kit")
        parts = []
    for component in target.split("/"):
        if component in ("", "."):
            continue
        if component == "..":
            if not parts:
                raise ValueError("payload symlink escapes its root")
            parts.pop()
        else:
            parts.append(component)
    if guest and (not parts or parts[0] not in PREFIXES):
        raise ValueError("payload symlink leaves the allowed FHS prefixes")


def entries(root: Path) -> list[Entry]:
    result: list[Entry] = []
    for path in sorted(root.rglob("*")):
        relative = str(path.relative_to(root))
        if relative == "kit.json":
            continue
        metadata = path.lstat()
        if stat.S_ISDIR(metadata.st_mode):
            continue
        mode = stat.S_IMODE(metadata.st_mode)
        if stat.S_ISREG(metadata.st_mode):
            if mode & 0o7022:
                raise ValueError("payload must not be privileged or writable by group/others")
            data = kernel.read_file(path, MAX_PAYLOAD)
            result.append(Entry(relative, "file", hashlib.sha256(data).hexdigest(), mode))
        elif stat.S_ISLNK(metadata.st_mode):
            target = os.readlink(path)
            check_symlink(relative, target)
            result.append(Entry(relative, "symlink", "", 0o777, target))
        else:
            raise ValueError("payload contains a special file")
    return result


def entry_json(entry: Entry) -> dict[str, kernel.JSON]:
    return {
        "name": entry.name,
        "kind": entry.kind,
        "sha256": entry.digest,
        "mode": entry.mode,
        "target": entry.target,
    }


def checked_entries(value: kernel.JSON) -> list[Entry]:
    if not isinstance(value, list) or not 0 < len(value) <= 32768:
        raise ValueError("a bounded installed payload list is required")
    entries: list[Entry] = []
    seen: set[str] = set()
    for item in value:
        row = kernel.object_value(item)
        name, kind, digest, mode, target = (
            row.get(key) for key in ("name", "kind", "sha256", "mode", "target")
        )
        if (
            not isinstance(name, str)
            or not name.startswith("root/")
            or len(Path(name).parts) < 3
            or Path(name).parts[1] not in PREFIXES
            or str(Path(name)) != name
            or Path(name).is_absolute()
            or ".." in Path(name).parts
            or name in seen
            or not isinstance(kind, str)
            or kind not in ("file", "symlink")
            or not isinstance(digest, str)
            or type(mode) is not int
            or not 0 <= mode <= 0o777
            or not isinstance(target, str)
        ):
            raise ValueError("invalid installed payload entry")
        if kind == "file":
            kernel.digest(digest)
        else:
            check_symlink(name, target)
        seen.add(name)
        entries.append(Entry(name, kind, digest, mode, target))
    return entries


def check_installed(root: Path, files: list[Entry], *, runtime_trust: bool = False) -> None:
    """@cc [owner:ghuntley,label:verification] native-image-exact-installed-payload
    Offline installation MUST verify every payload digest and mode. Runtime
    verification MUST preserve every static check except the one designated CA
    destination, which MUST pass the reviewed managed-trust state validation.
    """
    if runtime_trust:
        check_effective_trust(root, files)
    for entry in files:
        if runtime_trust and entry.name == TRUST_DESTINATION:
            continue
        path = root / Path(entry.name).relative_to("root")
        metadata = path.lstat()
        if metadata.st_uid != 0:
            raise ValueError("installed payload must remain root-owned")
        if entry.name == SUDOERS:
            kernel.destination(root, "etc/sudoers")
            if (
                not stat.S_ISREG(metadata.st_mode)
                or metadata.st_gid != 0
                or stat.S_IMODE(metadata.st_mode) != 0o440
                or entry.mode != 0o440
            ):
                raise ValueError("installed sudoers must be root:root regular mode0440")
        if entry.kind == "symlink":
            if not stat.S_ISLNK(metadata.st_mode) or os.readlink(path) != entry.target:
                raise ValueError("installed symbolic link differs")
        elif (
            stat.S_IMODE(metadata.st_mode) != entry.mode
            or hashlib.sha256(kernel.read_file(path, MAX_PAYLOAD)).hexdigest() != entry.digest
        ):
            raise ValueError("installed payload bytes or mode differ")


def check_trust_roots(data: bytes) -> None:
    count = 0
    offset = 0
    pattern = (
        rb"-----BEGIN CERTIFICATE-----\n([A-Za-z0-9+/=\r\n]+)-----END CERTIFICATE-----[ \t\r\n]*"
    )
    for match in re.finditer(pattern, data):
        if match.start() != offset or match.end() - match.start() > MAX_TRUST_CERT + 1:
            raise ValueError("invalid managed native trust certificate framing")
        try:
            der = base64.b64decode(re.sub(rb"[\r\n]", b"", match[1]), validate=True)
        except binascii.Error as error:
            raise ValueError("invalid managed native trust certificate encoding") from error
        if not der:
            raise ValueError("empty managed native trust certificate")
        count += 1
        offset = match.end()
    if not 1 <= count <= 32 or offset != len(data):
        raise ValueError("invalid managed native trust certificate set")


def check_effective_trust(root: Path, files: list[Entry]) -> None:
    """@cc [owner:ghuntley,label:security;verification] native-image-managed-trust-state
    The immutable regular vendor CA snapshot MUST retain its exact kit digest.
    Only the designated effective CA path MAY change from exact vendor bytes to
    a root-owned link into the fixed managed directory. Its regular mode0644
    target MUST contain the exact vendor prefix and one to 32 bounded PEM roots.
    Foreign links, writable paths and other payload changes MUST refuse. This
    structural check MUST NOT establish current-boot trust authority; only the
    daemon's boot-bound protocol receipt can establish that authority.
    """
    records: dict[str, Entry] = {}
    for name in (TRUST_BASE, TRUST_DESTINATION):
        matching = [entry for entry in files if entry.name == name]
        if len(matching) != 1 or matching[0].kind != "file" or matching[0].mode != 0o444:
            raise ValueError("exact regular native vendor trust records are required")
        records[name] = matching[0]
    if records[TRUST_BASE].digest != records[TRUST_DESTINATION].digest:
        raise ValueError("native vendor trust snapshots differ")
    base = kernel.destination(root, str(Path(TRUST_BASE).relative_to("root")))
    original = kernel.read_file(base, MAX_TRUST_BASE)
    if hashlib.sha256(original).hexdigest() != records[TRUST_BASE].digest:
        raise ValueError("immutable native vendor trust differs")
    relative = Path(TRUST_DESTINATION).relative_to("root")
    kernel.destination(root, str(relative.parent))
    destination = root / relative
    metadata = destination.lstat()
    if metadata.st_uid != 0 or metadata.st_gid != 0:
        raise ValueError("effective native trust must remain root-owned")
    if stat.S_ISREG(metadata.st_mode):
        if (
            stat.S_IMODE(metadata.st_mode) != 0o444
            or kernel.read_file(destination, MAX_TRUST_BASE) != original
        ):
            raise ValueError("initial native trust differs from vendor snapshot")
        return
    if not stat.S_ISLNK(metadata.st_mode):
        raise ValueError("effective native trust must be a regular file or managed link")
    target = os.readlink(destination)
    if re.fullmatch(r"/var/lib/overalls-trust/bundle-[0-9a-f]{64}\.pem", target) is None:
        raise ValueError("effective native trust link leaves the managed directory")
    path = kernel.destination(root, str(Path(target).relative_to("/")))
    linked = path.lstat()
    if (
        not stat.S_ISREG(linked.st_mode)
        or linked.st_uid != 0
        or linked.st_gid != 0
        or stat.S_IMODE(linked.st_mode) != 0o644
    ):
        raise ValueError("managed native trust must be a regular root-owned mode0644 file")
    bundle = kernel.read_file(path, MAX_TRUST_BASE + 1 + 32 * (MAX_TRUST_CERT + 1))
    prefix = original if original.endswith(b"\n") else original + b"\n"
    if not bundle.startswith(prefix):
        raise ValueError("managed native trust lost its immutable vendor prefix")
    check_trust_roots(bundle[len(prefix) :])


def installation_entries(files: list[Entry]) -> list[Entry]:
    """@cc [owner:ghuntley,label:security;build] native-image-sudoers-mode
    The exact kit bytes MUST remain verified independently from target modes.
    Only the reviewed regular sudoers file MUST recover target mode0440 after
    Nix publication. Installation and secondboot receipts MUST bind that mode,
    and its destination and ancestors MUST refuse symlink traversal.
    """
    selected = [entry for entry in files if entry.name.startswith("root/")]
    policy = [entry for entry in selected if entry.name == SUDOERS]
    if len(policy) != 1 or policy[0].kind != "file":
        raise ValueError("one regular reviewed sudoers file is required")
    return [
        Entry(entry.name, entry.kind, entry.digest, 0o440, entry.target)
        if entry.name == SUDOERS
        else entry
        for entry in selected
    ]


def stream_digest(path: Path, size: int) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        remaining = size
        while remaining:
            data = stream.read(min(remaining, 1024 * 1024))
            if not data:
                raise ValueError("disk ended before the expected pinned image length")
            digest.update(data)
            remaining -= len(data)
        if stream.read(1):
            raise ValueError("scratch disk is larger than the pinned image")
    return digest.hexdigest()


def pack(root: Path, expected: str, python_sha256: str, base: Path) -> None:
    kernel.digest(expected)
    kernel.digest(python_sha256)
    # Nix publishes regular files as0444 or0555 according to owner-execute.
    # Bind those final source modes, not the builder's temporary write bits.
    for entry in entries(root):
        if entry.kind == "file":
            (root / entry.name).chmod(0o555 if entry.mode & 0o100 else 0o444)
    kernel.write_json(
        root / "kit.json",
        {
            "version": 1,
            "os": "illumos",
            "build_id": expected,
            "python_version": "3.12.3",
            "python_sha256": python_sha256,
            "base_bytes": base.stat().st_size,
            "base_sha256": stream_digest(base, base.stat().st_size),
            "files": [entry_json(entry) for entry in entries(root)],
            "native_admission": False,
        },
    )


def check_kit(root: Path, expected: str, *, native_runtime: bool = True) -> list[Entry]:
    """Reject changed payloads and stock network authority before pool access."""
    data = kernel.read_file(root / "kit.json", MAX_MANIFEST)
    parsed: object = json.loads(data)
    receipt = kernel.object_value(kernel.json_value(parsed))
    actual = entries(root)
    if (
        receipt.get("version") != 1
        or receipt.get("os") != "illumos"
        or receipt.get("build_id") != kernel.digest(expected)
        or receipt.get("native_admission") is not False
        or receipt.get("files") != [entry_json(entry) for entry in actual]
    ):
        raise ValueError("installation kit identity or exact payload differs")
    forbidden = {f"root/{relative}" for relative in STOCK_NETWORK_FILES}
    if any(entry.name in forbidden for entry in actual):
        raise ValueError("native kit must not configure stock network authority")
    if native_runtime:
        kernel.destination(Path("/"), str(root.relative_to("/")))
        for path in (root, *root.rglob("*")):
            metadata = path.lstat()
            if stat.S_ISLNK(metadata.st_mode):
                if metadata.st_uid != 0:
                    raise ValueError("native installation kit links must be root-owned")
            else:
                kernel.check_ownership(metadata)
        python_hash = receipt.get("python_sha256")
        if (
            receipt.get("python_version") != "3.12.3"
            or sys.version_info[:3] != (3, 12, 3)
            or not isinstance(python_hash, str)
            or kernel.digest(python_hash)
            != hashlib.sha256(kernel.read_file(Path(sys.executable).resolve())).hexdigest()
        ):
            raise ValueError("the pinned OmniOS native Python runtime is required")
    return actual


def pool_guid(value: str) -> str:
    if re.fullmatch(r"[1-9][0-9]{0,19}", value) is None or int(value) >= 1 << 64:
        raise ValueError("expected a positive decimal ZFS pool GUID")
    return value


def check_device(device: Path, expected_guid: str, imported_guids: str) -> None:
    pool_guid(expected_guid)
    if expected_guid in imported_guids.split():
        raise ValueError("scratch pool must not already be imported, including the running root")
    if (
        not device.is_absolute()
        or device.parent != Path("/dev/dsk")
        or re.fullmatch(r"c[0-9]+(?:t[0-9A-Fa-f]+)?d[0-9]+s[0-9]+", device.name) is None
        or not stat.S_ISBLK(device.stat().st_mode)
    ):
        raise ValueError("an explicit native /dev/dsk block partition is required")


def check_base(kit: Path, device: Path) -> None:
    parsed: object = json.loads(kernel.read_file(kit / "kit.json", MAX_MANIFEST))
    receipt = kernel.object_value(kernel.json_value(parsed))
    size = receipt.get("base_bytes")
    expected = receipt.get("base_sha256")
    if type(size) is not int or not 0 < size <= 1 << 40 or not isinstance(expected, str):
        raise ValueError("pinned whole-disk length and digest are required")
    # OmniOS p0 names the complete GPT disk, while s0 is its ZFS partition.
    raw = Path("/dev/rdsk") / re.sub(r"s[0-9]+$", "p0", device.name)
    resolved = raw.resolve(strict=True)
    if not stat.S_ISCHR(resolved.stat().st_mode):
        raise ValueError("scratch whole disk must be a native raw character device")
    if stream_digest(resolved, size) != kernel.digest(expected):
        raise ValueError("scratch disk does not exactly match the pinned OmniOS image")


def merge_root(root: Path, payload: Path, files: list[Entry]) -> None:
    selected = [entry for entry in files if entry.name.startswith("root/")]
    # Preflight every destination before writing any payload bytes. Source
    # symlinks are installed atomically and are never traversed during assembly.
    for entry in selected:
        relative = Path(entry.name).relative_to("root")
        if relative.parts[0] not in PREFIXES or ".." in relative.parts:
            raise ValueError("unexpected FHS payload destination")
        kernel.destination(root, str(relative.parent))
        if entry.name == SUDOERS:
            kernel.destination(root, str(relative))
    for entry in selected:
        relative = Path(entry.name).relative_to("root")
        path = root / relative
        kernel.destination(root, str(relative.parent)).mkdir(parents=True, exist_ok=True)
        if entry.kind == "file":
            # install_file rejects pre-existing final symlinks; replacing such
            # links explicitly first does not follow them outside the clone.
            if path.is_symlink():
                path.unlink()
            kernel.install_file(
                root, str(relative), kernel.read_file(payload / entry.name, MAX_PAYLOAD), entry.mode
            )
        else:
            temporary = path.with_name(path.name + ".overalls-new")
            os.symlink(entry.target, temporary)
            temporary.replace(path)


def native_root() -> None:
    kernel.native()
    if os.geteuid() != 0:
        raise ValueError("native image assembly requires root")


def check_disabled_service_properties(output: str) -> None:
    rows = [line.split() for line in output.splitlines()]
    if rows != [["general/enabled", "boolean", "false"] for _ in STOCK_SERVICES]:
        raise ValueError("every stock automation and SSH instance must be disabled")


def disable_stock_services() -> None:
    """@cc [owner:ghuntley,label:security;build] native-image-offline-service-authority
    Assembly MUST disable all four stock cloud-init instances and stock SSH in
    only the cloned scratch root's SMF repository. The installed site profile
    MUST preserve that choice at boot; resolver bytes MUST remain bound to the
    verified payload. Commands MUST select the offline repository before any
    mutation, import the fixed stock manifests into a seed repository, bind the
    same repository through SVCCFG_REPOSITORY to prevent live-restarter waits,
    and refuse an incomplete or non-false enabled-property result.
    """
    repository = kernel.destination(ROOT, "etc/svc/repository.db")
    if not stat.S_ISREG(repository.lstat().st_mode):
        raise ValueError("scratch SMF repository must be a regular file")
    profile = kernel.destination(ROOT, SERVICE_PROFILE)
    kernel.read_file(profile, 65536)
    commands = [f"repository {repository}"]
    for relative in STOCK_SERVICE_MANIFESTS:
        manifest = kernel.destination(ROOT, relative)
        kernel.read_file(manifest, 65536)
        commands.append(f"import {manifest}")
    commands.append(f"apply {profile}")
    for fmri in STOCK_SERVICES:
        commands.extend((f"select {fmri}", "listprop general/enabled", "unselect"))
    script = WORK / "disable-stock-services.svccfg"
    with script.open("x", encoding="ascii") as stream:
        stream.write("\n".join(commands) + "\n")
    script.chmod(0o600)
    # The repository command alone does not mark imports as offline in the
    # vendor implementation: without this environment selector, import waits
    # for a restarter that cannot observe the private repository.
    check_disabled_service_properties(
        kernel.command(
            [
                "/usr/bin/env",
                f"SVCCFG_REPOSITORY={repository}",
                "/usr/sbin/svccfg",
                "-f",
                str(script),
            ]
        )
    )


def check_stock_services_disabled() -> None:
    for fmri in STOCK_SERVICES:
        if (
            kernel.command(["/usr/bin/svcprop", "-p", "general/enabled", fmri]).strip() != "false"
            or kernel.command(["/usr/bin/svcs", "-H", "-o", "state", fmri]).strip() != "disabled"
        ):
            raise ValueError("stock automation and SSH must remain disabled after boot")


def remove_stock_network(root: Path) -> None:
    """@cc [owner:ghuntley,label:build;security] native-image-network-handoff
    Assembly MUST remove the fixed stock vioif0 address/DHCP files only from
    the scratch clone, refusing links and nonregular files before any removal.
    A plumb-only hostname file MUST NOT block stock network/physical with an
    unusable zero address; the later growth-gated MMDS bootstrap owns plumbing
    and static addresses. Unrelated interface configuration MUST be preserved.
    """
    paths = [kernel.destination(root, relative) for relative in STOCK_NETWORK_FILES]
    for path in paths:
        if path.exists() and not stat.S_ISREG(path.lstat().st_mode):
            raise ValueError("stock network configuration must be a regular file")
    for path in paths:
        path.unlink(missing_ok=True)


def check_stock_network_absent(root: Path) -> None:
    """Refuse restored stock configuration that competes with MMDS bootstrap."""
    for relative in STOCK_NETWORK_FILES:
        if kernel.destination(root, relative).exists():
            raise ValueError("stock network configuration must remain absent")


def check_agent_service_contract(data: bytes) -> None:
    """@cc [owner:ghuntley,label:recovery;build] native-agent-smf-signal-policy
    The native agents manifest MUST select the contract service model and ignore
    only external signal failures, so SMF does not replace the live listeners
    when the shell supervisor reaps an individually killed daemon. Missing,
    duplicate or broader error policies MUST refuse; core, hardware and empty
    contract failures MUST retain their outer restart boundary.
    """
    try:
        document = ET.fromstring(data)
    except ET.ParseError:
        raise ValueError("native agents require the exact SMF signal policy") from None
    services = document.findall("./service")
    if len(services) != 1 or services[0].get("name") != "site/overalls-native-agents":
        raise ValueError("native agents require the exact SMF signal policy")
    groups = services[0].findall("./property_group[@name='startd']")
    if (
        len(groups) != 1
        or groups[0].get("type") != "framework"
        or document.findall(".//property_group[@name='startd']") != groups
    ):
        raise ValueError("native agents require the exact SMF signal policy")
    properties = list(groups[0])
    expected = {
        ("duration", "astring", "contract"),
        ("ignore_error", "astring", "signal"),
    }
    if (
        len(properties) != len(expected)
        or any(item.tag != "propval" for item in properties)
        or {(item.get("name"), item.get("type"), item.get("value")) for item in properties}
        != expected
    ):
        raise ValueError("native agents require the exact SMF signal policy")


def validate_native_services(root: Path) -> None:
    """@cc [owner:ghuntley,label:build;verification] native-service-manifest-schema
    Assembly and booted verification MUST validate all three exact installed
    native service manifests with the pinned target's real svccfg validator.
    Missing, linked or schema-invalid manifests MUST refuse before a receipt;
    valid XML alone MUST NOT establish service import or runtime readiness.
    """
    paths = [kernel.destination(root, relative) for relative in NATIVE_SERVICE_MANIFESTS]
    for path in paths:
        data = kernel.read_file(path, 65536)
        if path.name == "overalls-native-agents.xml":
            check_agent_service_contract(data)
    for path in paths:
        kernel.command(["/usr/sbin/svccfg", "validate", str(path)])


def check_native_ssh_executable(root: Path) -> None:
    """@cc [owner:ghuntley,label:build;verification] native-ssh-executable-closure
    Assembly and booted verification MUST require the supervisor's native sshd
    path to be a root-owned regular executable ELF within the checked guest
    root. Missing, linked, group/other-writable or privileged executables MUST refuse.
    This file check MUST NOT establish SSH configuration or runtime readiness.
    """
    path = kernel.destination(root, NATIVE_SSHD)
    metadata = path.lstat()
    if (
        not stat.S_ISREG(metadata.st_mode)
        or metadata.st_uid != 0
        or not metadata.st_mode & stat.S_IXUSR
        or metadata.st_mode & 0o7022
        or not kernel.read_file(path, MAX_PAYLOAD).startswith(b"\x7fELF")
    ):
        raise ValueError("native sshd must be a safe root-owned executable ELF")


def _remove_transient_single_user(data: bytes) -> bytes:
    """Remove only the standalone ``-s`` boot argument from transient state."""
    lines = data.splitlines(keepends=True)
    result: list[bytes] = []
    for line in lines:
        if line.startswith(b"boot-args="):
            line = re.sub(rb"(?P<prefix>[ \t])-s(?P<suffix>[ \t]+)", rb"\g<prefix>", line)
            line = re.sub(rb"(?P<prefix>[ \t])-s(?P<quote>[\"\\'])", rb"\g<quote>", line)
            line = re.sub(rb"(?P<quote>[\"\\'])-s(?P<suffix>[ \t]+)", rb"\g<quote>", line)
            line = re.sub(rb"(?P<quote>[\"\\'])-s(?P<end>[\"\\'])", rb"\g<quote>\g<end>", line)
        result.append(line)
    return b"".join(result)


def sanitize_transient_configuration(root: Path) -> None:
    """@cc [owner:ghuntley,label:build;security;verification] native-transient-single-user
    The cloned OmniOS transient loader configuration MUST NOT retain a standalone
    ``-s`` boot argument inherited from the administration boot. Other transient
    boot arguments, including the ZFS root and console binding, MUST be preserved
    byte-for-byte; missing transient state is allowed.
    """
    path = kernel.destination(root, TRANSIENT_CONFIG)
    if not path.exists():
        return
    metadata = path.lstat()
    if not stat.S_ISREG(metadata.st_mode) or stat.S_IMODE(metadata.st_mode) & 0o022:
        raise ValueError("native transient configuration must be a safe regular file")
    original = kernel.read_file(path, MAX_TRANSIENT)
    sanitized = _remove_transient_single_user(original)
    if sanitized != original:
        kernel.install_file(root, TRANSIENT_CONFIG, sanitized, stat.S_IMODE(metadata.st_mode))


def check_transient_configuration(root: Path) -> None:
    """@cc [owner:ghuntley,label:verification] native-transient-single-user-receipt
    Boot verification MUST reject a present transient loader configuration that
    still contains a standalone ``-s`` argument, while allowing a missing file.
    """
    path = kernel.destination(root, TRANSIENT_CONFIG)
    if not path.exists():
        return
    data = kernel.read_file(path, MAX_TRANSIENT)
    if _remove_transient_single_user(data) != data:
        raise ValueError("native transient configuration still requests single-user boot")


def configure_console(root: Path) -> list[Entry]:
    """@cc [owner:ghuntley,label:build;verification] native-image-serial-handoff
    Only the scratch clone MUST receive the reviewed pseudo ISA nexus and ttya
    loader/kernel settings. Existing configuration bytes MUST be preserved,
    destinations and ancestors MUST refuse symlinks, and both final regular
    files MUST enter the exact installed payload receipt. Debugger, singleuser
    and verbose boot flags MUST NOT be introduced by this configuration.
    """
    configured: list[tuple[str, bytes]] = []
    for relative, suffix in CONSOLE_SETTINGS.items():
        path = kernel.destination(root, relative)
        if relative == "etc/system" and not path.exists():
            raise ValueError("the pinned stock system configuration is required")
        previous = kernel.read_file(path, 65536) if path.exists() else b""
        if len(previous) + len(suffix) > 65536:
            raise ValueError("native console configuration exceeds its bound")
        configured.append((relative, previous + suffix))
    result: list[Entry] = []
    for relative, data in configured:
        kernel.install_file(root, relative, data)
        result.append(Entry(f"root/{relative}", "file", hashlib.sha256(data).hexdigest(), 0o644))
    return result


def check_console_configuration(root: Path, files: list[Entry]) -> None:
    """@cc [owner:ghuntley,label:verification] native-image-console-receipt
    Secondboot verification MUST require exactly one regular mode0644 record
    for each console file, its exact digest and the reviewed terminal settings.
    Missing, duplicate, substituted or symlinked configuration MUST refuse.
    """
    selected: list[tuple[str, bytes, Entry]] = []
    for relative, suffix in CONSOLE_SETTINGS.items():
        matching = [entry for entry in files if entry.name == f"root/{relative}"]
        if len(matching) != 1 or matching[0].kind != "file" or matching[0].mode != 0o644:
            raise ValueError("both regular console configuration payload records are required")
        selected.append((relative, suffix, matching[0]))
    for relative, suffix, entry in selected:
        path = kernel.destination(root, relative)
        data = kernel.read_file(path, 65536)
        if not data.endswith(suffix) or hashlib.sha256(data).hexdigest() != entry.digest:
            raise ValueError("installed native console configuration differs")


def cleanup_assembly_workspace(imported_here: bool) -> None:
    """@cc [owner:ghuntley,label:recovery;security] native-assembly-cleanup
    When the candidate pool was imported, the workspace MUST be removed only
    after a successful export. If export refuses, the helper MUST preserve the
    workspace and propagate the export failure so an operator can recover the
    still-imported pool. A workspace created before import may be removed on
    failure because it contains no imported guest dataset.
    """
    if imported_here:
        # Do not put this call in a ``try`` that falls through to rmtree: an
        # export refusal means the workspace may still contain mounted ZFS
        # datasets, and removing it would destroy the recovery path.
        kernel.command(["/usr/sbin/zpool", "export", POOL], 120)
    shutil.rmtree(WORK)


def assemble(kit: Path, device: Path, guid: str, expected: str) -> None:
    """@cc [owner:ghuntley,label:build;isolation;verification] native-scratch-pool-assembly
    Assembly MUST import only the explicitly selected, previously unimported
    scratch pool through a private device directory. It MUST refuse the running
    pool, clone the pinned BE, verify all kit bytes and pinned native Python,
    install the complete module/service/Git roots and rebuild the boot archive.
    It MUST attempt clean pool export on success and failure, preserving the
    workspace if export refuses. It MUST NOT publish production manifests or
    grant native catalog admission.
    """
    native_root()
    files = check_kit(kit, expected)
    imported = kernel.command(["/usr/sbin/zpool", "list", "-H", "-o", "guid"])
    check_device(device, guid, imported)
    if POOL in kernel.command(["/usr/sbin/zpool", "list", "-H", "-o", "name"]).split():
        raise ValueError("the candidate pool name must not already be imported")
    check_base(kit, device)
    if WORK.exists() or WORK.is_symlink():
        raise ValueError("assembly workspace must not already exist")
    kernel.destination(Path("/"), str(WORK.relative_to("/")))
    WORK.mkdir(mode=0o700)
    device_dir = WORK / "devices"
    device_dir.mkdir(mode=0o700)
    (device_dir / "scratch").symlink_to(device)
    imported_here = False
    try:
        kernel.command(
            [
                "/usr/sbin/zpool",
                "import",
                "-f",
                "-N",
                "-R",
                str(WORK),
                "-d",
                str(device_dir),
                guid,
                POOL,
            ]
        )
        imported_here = True
        kernel.command(["/usr/sbin/zfs", "list", "-H", "-o", "name", SOURCE])
        if (
            kernel.command(["/usr/sbin/zpool", "get", "-H", "-o", "value", "guid", POOL]).strip()
            != guid
        ):
            raise ValueError("imported scratch pool GUID differs")
        snapshot = f"{SOURCE}@overalls-native-{expected}"
        kernel.command(["/usr/sbin/zfs", "snapshot", snapshot])
        kernel.command(
            [
                "/usr/sbin/zfs",
                "clone",
                "-o",
                "canmount=noauto",
                "-o",
                "mountpoint=/candidate",
                snapshot,
                TARGET,
            ]
        )
        kernel.command(["/usr/sbin/zfs", "mount", TARGET])
        kernel.alternate_root(ROOT, kernel.command(["/usr/sbin/mount", "-p"]))
        linked = WORK / "linked"
        kernel.link(kit / "kernel", expected, linked)
        installed = installation_entries(files)
        merge_root(ROOT, kit, installed)
        installed.extend(configure_console(ROOT))
        sanitize_transient_configuration(ROOT)
        check_installed(ROOT, installed)
        check_console_configuration(ROOT, installed)
        validate_native_services(ROOT)
        check_native_ssh_executable(ROOT)
        disable_stock_services()
        remove_stock_network(ROOT)
        check_stock_network_absent(ROOT)
        kernel.install(ROOT, linked, expected)
        # The stock unix file remains the kernel-file identity. Nine patched
        # module digests stay separate, bound again by the final raw-disk hash.
        linked_receipt, _ = kernel.receipt(linked / kernel.EVIDENCE / "linked-receipt.json")
        unix = kernel.read_file(ROOT / "platform/i86pc/kernel/amd64/unix")
        assembly: dict[str, kernel.JSON] = {
            "version": 1,
            "os": "illumos",
            "build_id": expected,
            "dataset": TARGET,
            "pool_guid": guid,
            "unix": kernel.json_value(kernel.file_record("platform/i86pc/kernel/amd64/unix", unix)),
            "modules": linked_receipt["modules"],
            "payload_files": [entry_json(entry) for entry in installed],
            "disabled_stock_services": list(STOCK_SERVICES),
            "removed_stock_network_files": list(STOCK_NETWORK_FILES),
            "native_service_manifests_validated": True,
            "native_ssh_executable_checked": True,
            "transient_single_user_sanitized": True,
            "native_admission": False,
            "runtime_validated": False,
        }
        assembly_bytes = (json.dumps(assembly, sort_keys=True, indent=2) + "\n").encode()
        if len(assembly_bytes) > MAX_MANIFEST:
            raise ValueError("assembled candidate receipt exceeds its explicit bound")
        kernel.install_file(ROOT, RECEIPT, assembly_bytes)
        kernel.command(["/usr/sbin/bootadm", "update-archive", "-R", str(ROOT)], 600)
        kernel.command(["/usr/sbin/zfs", "unmount", TARGET])
        kernel.command(["/usr/sbin/zfs", "set", "mountpoint=legacy", TARGET])
        kernel.command(["/usr/sbin/zpool", "set", f"bootfs={TARGET}", POOL])
    finally:
        cleanup_assembly_workspace(imported_here)


def verify(expected: str) -> None:
    """@cc [owner:ghuntley,label:verification;security] native-candidate-second-boot
    Verification MUST check the booted clone, actual unix and all nine installed
    module bytes, and the running socket getter's exact compiled token. File
    installation or boot success MUST NOT imply services, isolation or admission.
    """
    native_root()
    kernel.digest(expected)
    value: object = json.loads(kernel.read_file(Path("/") / RECEIPT, MAX_MANIFEST))
    parsed = kernel.object_value(kernel.json_value(value))
    if (
        parsed.get("build_id") != expected
        or parsed.get("dataset") != TARGET
        or parsed.get("disabled_stock_services") != list(STOCK_SERVICES)
        or parsed.get("removed_stock_network_files") != list(STOCK_NETWORK_FILES)
        or parsed.get("native_service_manifests_validated") is not True
        or parsed.get("native_ssh_executable_checked") is not True
        or parsed.get("transient_single_user_sanitized") is not True
        or parsed.get("native_admission") is not False
    ):
        raise ValueError("expected closed candidate assembly receipt")
    mounts = kernel.command(["/usr/sbin/mount", "-p"])
    if not any(line.split()[:4] == [TARGET, "-", "/", "zfs"] for line in mounts.splitlines()):
        raise ValueError("the assembled candidate is not the running ZFS root")
    kernel.verified_file(
        Path("/") / "platform/i86pc/kernel/amd64/unix", kernel.object_value(parsed.get("unix"))
    )
    modules = parsed.get("modules")
    if not isinstance(modules, list) or len(modules) != len(kernel.MODULES):
        raise ValueError("nine installed module records required")
    records: dict[str, dict[str, kernel.JSON]] = {}
    for item in modules:
        record = kernel.object_value(item)
        name = record.get("name")
        if not isinstance(name, str) or name in records:
            raise ValueError("duplicate or invalid installed module name")
        records[name] = record
    if set(records) != {module.name for module in kernel.MODULES}:
        raise ValueError("installed module set differs")
    for module in kernel.MODULES:
        kernel.verified_file(Path("/") / module.destination, records[module.name])
    installed = checked_entries(parsed.get("payload_files"))
    if installed != installation_entries(installed):
        raise ValueError("installed sudoers receipt must bind target mode0440")
    check_installed(Path("/"), installed, runtime_trust=True)
    check_console_configuration(Path("/"), installed)
    check_transient_configuration(Path("/"))
    check_stock_services_disabled()
    check_stock_network_absent(Path("/"))
    validate_native_services(Path("/"))
    check_native_ssh_executable(Path("/"))
    kernel.command(["/usr/bin/git", "--version"])
    with socket.socket(40, socket.SOCK_STREAM, 0) as stream:
        if stream.getsockopt(40, 1, 65) != expected.encode("ascii") + b"\0":
            raise ValueError("running native socket build token differs")
    kernel.install_file(
        Path("/"),
        "etc/overalls/native-image/verified-receipt.json",
        (
            json.dumps(
                {
                    "version": 1,
                    "build_id": expected,
                    "booted_clone_checked": True,
                    "unix_digest_checked": True,
                    "module_digests_checked": True,
                    "payload_digests_checked": True,
                    "console_configuration_checked": True,
                    "transient_single_user_checked": True,
                    "git_runtime_checked": True,
                    "vendor_trust_digest_checked": True,
                    "effective_trust_path_checked": True,
                    "current_boot_trust_validated": False,
                    "sudoers_owner_and_mode_checked": True,
                    "stock_automation_and_ssh_disabled": True,
                    "stock_network_configuration_absent": True,
                    "native_service_manifests_validated": True,
                    "native_ssh_executable_checked": True,
                    "compiled_socket_token_checked": True,
                    "native_services_validated": False,
                    "isolation_validated": False,
                    "native_admission": False,
                },
                sort_keys=True,
                indent=2,
            )
            + "\n"
        ).encode(),
    )


def main(arguments: list[str]) -> None:
    if len(arguments) == 5 and arguments[0] == "pack":
        pack(Path(arguments[1]), arguments[2], arguments[3], Path(arguments[4]))
    elif len(arguments) == 5 and arguments[0] == "assemble":
        assemble(Path(arguments[1]).resolve(), Path(arguments[2]), arguments[3], arguments[4])
    elif len(arguments) == 2 and arguments[0] == "verify":
        verify(arguments[1])
    else:
        raise ValueError(
            "usage: native_image.py pack KIT BUILD_ID PYTHON_SHA256 PINNED_RAW | assemble KIT DEVICE POOL_GUID BUILD_ID | verify BUILD_ID"
        )


if __name__ == "__main__":
    main(sys.argv[1:])
