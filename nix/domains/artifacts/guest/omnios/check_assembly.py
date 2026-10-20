"""Validate guest-extracted OmniOS assembly evidence and emit the test-only manifest."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path
from typing import TypedDict

FRAMEWORK = ("virtio", "vioblk", "vioif", "vioscsi", "vio9p", "viorand", "sockfs")
TRANSPORT = ("viosock", "sockvsock")
MODULE_PATHS = {
    "virtio": "kernel/misc/amd64/virtio",
    "vioblk": "kernel/drv/amd64/vioblk",
    "vioif": "kernel/drv/amd64/vioif",
    "vioscsi": "kernel/drv/amd64/vioscsi",
    "vio9p": "kernel/drv/amd64/vio9p",
    "viorand": "kernel/drv/amd64/viorand",
    "sockfs": "kernel/fs/amd64/sockfs",
    "viosock": "kernel/drv/amd64/viosock",
    "sockvsock": "kernel/socketmod/amd64/sockvsock",
}
MODULE_OBJECTS = {
    "virtio": ("virtio_main", "virtio_dma", "virtio_legacy", "virtio_modern"),
    "vioblk": ("vioblk",),
    "vioif": ("vioif",),
    "vioscsi": ("vioscsi",),
    "vio9p": ("vio9p",),
    "viorand": ("viorand",),
    "sockfs": (
        "socksubr",
        "sockvfsops",
        "sockparams",
        "socksyscalls",
        "socktpi",
        "sockstr",
        "sockcommon_vnops",
        "sockcommon_subr",
        "sockcommon_sops",
        "sockcommon",
        "sock_notsupp",
        "socknotify",
        "sodirect",
        "sockfilter",
    ),
    "viosock": ("viosock", "ov_vsock"),
    "sockvsock": ("sockvsock",),
}
UNIX = "platform/i86pc/kernel/amd64/unix"
HEX64 = re.compile(r"[0-9a-f]{64}")


class Record(TypedDict):
    name: str
    bytes: int
    sha256: str


class Reference(TypedDict):
    receipt_sha256: str
    build_id: str
    unix: Record
    modules: list[Record]
    objects: dict[str, str]


class Options(argparse.Namespace):
    evidence: Path
    kit: Path
    disk: Path
    reference: Path
    build_id: str
    output: Path


def mapping(value: object) -> dict[str, object]:
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        raise ValueError("expected a JSON object")
    return {str(key): item for key, item in value.items()}


def load(path: Path) -> dict[str, object]:
    parsed: object = json.loads(path.read_bytes())
    return mapping(parsed)


def sha256(value: str) -> str:
    if HEX64.fullmatch(value) is None:
        raise ValueError("expected lowercase SHA-256")
    return value


def record(value: object) -> Record:
    item = mapping(value)
    name = item.get("name")
    size = item.get("bytes")
    digest = item.get("sha256")
    if not isinstance(name, str) or type(size) is not int or size <= 0:
        raise ValueError("invalid file record")
    if not isinstance(digest, str):
        raise ValueError("invalid file digest")
    return {"name": name, "bytes": size, "sha256": sha256(digest)}


def records(value: object) -> dict[str, Record]:
    if not isinstance(value, list):
        raise ValueError("expected module records")
    result: dict[str, Record] = {}
    for item in value:
        parsed = record(item)
        if parsed["name"] in result:
            raise ValueError("duplicate module record")
        result[parsed["name"]] = parsed
    if set(result) != set(MODULE_PATHS):
        raise ValueError("the exact nine-module set is required")
    return result


def reference(path: Path) -> Reference:
    item = load(path)
    receipt = item.get("receipt_sha256")
    build_id = item.get("build_id")
    objects = mapping(item.get("objects"))
    if not isinstance(receipt, str) or not isinstance(build_id, str):
        raise ValueError("invalid promoted reference")
    object_digests: dict[str, str] = {}
    for name, digest in objects.items():
        if not isinstance(digest, str):
            raise ValueError("invalid promoted object digest")
        object_digests[name] = sha256(digest)
    return {
        "receipt_sha256": sha256(receipt),
        "build_id": sha256(build_id),
        "unix": record(item.get("unix")),
        "modules": list(records(item.get("modules")).values()),
        "objects": object_digests,
    }


def file_digest(path: Path) -> tuple[int, str]:
    digest = hashlib.sha256()
    size = 0
    with path.open("rb") as stream:
        while chunk := stream.read(1024 * 1024):
            size += len(chunk)
            digest.update(chunk)
    return size, digest.hexdigest()


def installed(path: Path) -> dict[str, str]:
    result: dict[str, str] = {}
    for line in path.read_text(encoding="ascii").splitlines():
        digest, _, name = line.partition(" ")
        if name in result:
            raise ValueError("duplicate installed digest")
        result[name] = sha256(digest)
    if set(result) != {*MODULE_PATHS.values(), UNIX}:
        raise ValueError("installed digest set differs")
    return result


def kit_objects(kit: Path) -> dict[str, str]:
    receipt = load(kit / "kernel/share/overalls/native-kernel/build-receipt.json")
    objects = receipt.get("objects")
    if not isinstance(objects, list):
        raise ValueError("kit object receipt missing")
    result: dict[str, str] = {}
    for item in objects:
        parsed = record(item)
        result[parsed["name"].removesuffix(".o")] = parsed["sha256"]
    return result


def check(options: Options) -> None:
    """@cc [owner:ghuntley,label:build;verification] omnios-assembly-evidence-check
    The host MUST bind guest-extracted receipts to the Nix build identity, the
    exact nine module digests installed on the exported root, the stock unix
    identity and the final raw disk. Modules whose exact objects equal the
    promoted kit's MUST reproduce the promoted module digests; changed inputs
    are recorded, never silently accepted. Output MUST keep admission false.
    """
    expected = sha256(options.build_id)
    evidence = options.evidence
    if (evidence / "guest-status").read_text(encoding="ascii") != f"assembled:{expected}\n":
        raise ValueError("guest did not complete the expected assembly")
    if (evidence / "kernel-build-id").read_text(encoding="ascii") != expected + "\n":
        raise ValueError("installed kernel build identity differs")
    assembly_path = evidence / "assembly-receipt.json"
    assembly = load(assembly_path)
    linked = load(evidence / "linked-receipt.json")
    install = load(evidence / "install-receipt.json")
    for document in (assembly, linked, install):
        if (
            document.get("build_id") != expected
            or document.get("os") != "illumos"
            or document.get("native_admission") is not False
            or document.get("runtime_validated") is not False
        ):
            raise ValueError("assembly receipt identity or closed scope differs")
    if linked.get("linked") is not True or linked.get("linker_contract") != "solaris-kmod":
        raise ValueError("native Solaris kmod linkage receipt required")
    modules = records(assembly.get("modules"))
    if records(linked.get("modules")) != modules:
        raise ValueError("installed modules differ from the linked receipt")
    digests = installed(evidence / "installed-modules.txt")
    for name, path in MODULE_PATHS.items():
        if digests[path] != modules[name]["sha256"]:
            raise ValueError(f"installed module {name} differs from its receipt")
    for name in TRANSPORT:
        size, digest = file_digest(evidence / "modules" / name)
        if (size, digest) != (modules[name]["bytes"], modules[name]["sha256"]):
            raise ValueError(f"extracted {name} bytes differ")
    promoted = reference(options.reference)
    pinned_pool = load(options.reference).get("pinned_pool_guid")
    pool_guid = (evidence / "pool-guid").read_text(encoding="ascii").strip()
    if not isinstance(pinned_pool, str) or pool_guid != pinned_pool:
        raise ValueError("scratch pool is not the pinned stock image's pool")
    if assembly.get("pool_guid") != pool_guid:
        raise ValueError("assembly receipt pool differs from the scratch slice label")
    unix = record(assembly.get("unix"))
    if unix != {**promoted["unix"], "name": unix["name"]} or digests[UNIX] != unix["sha256"]:
        raise ValueError("stock unix identity differs from the promoted image")
    current_objects = kit_objects(options.kit)
    promoted_modules = {item["name"]: item for item in promoted["modules"]}
    comparison: dict[str, str] = {}
    for name, objects in MODULE_OBJECTS.items():
        same_inputs = all(
            current_objects.get(item) == promoted["objects"].get(item) for item in objects
        )
        same_output = modules[name] == promoted_modules[name]
        if same_inputs and not same_output:
            raise ValueError(f"identical {name} objects did not reproduce the promoted module")
        comparison[name] = "reproduced-promoted" if same_output else "inputs-changed"
    disk_bytes, disk_sha256 = file_digest(options.disk)
    assembly_bytes, assembly_sha256 = file_digest(assembly_path)
    kit_bytes, kit_sha256 = file_digest(options.kit / "kit.json")
    kernel = {"bytes": unix["bytes"], "sha256": unix["sha256"]}
    manifest: dict[str, object] = {
        "assembly_sha256": assembly_sha256,
        "kernel": kernel,
        "kit_manifest_sha256": kit_sha256,
        "native_admission": False,
        "native_services_validated": False,
        "os": "illumos",
        "raw_bytes": disk_bytes,
        "raw_sha256": disk_sha256,
        "runtime_validated": False,
        "scope": "Nix KVM assembly of the exact candidate kit: guest-native Solaris kmod linkage, scratch-pool clone, installation, boot-archive rebuild and clean export. Normal boot, services, transport, reset, isolation, recovery and admission are unvalidated by this artifact. This is not a production v6 image manifest.",
        "test_only": True,
        "transport_build_id": expected,
    }
    receipt: dict[str, object] = {
        "version": 1,
        "os": "illumos",
        "build_id": expected,
        "assembly_receipt": {"bytes": assembly_bytes, "sha256": assembly_sha256},
        "kit_manifest": {"bytes": kit_bytes, "sha256": kit_sha256},
        "raw": {"bytes": disk_bytes, "sha256": disk_sha256},
        "unix": unix,
        "modules": [modules[name] for name in MODULE_PATHS],
        "promoted_reference": {
            "assembly_receipt_sha256": promoted["receipt_sha256"],
            "build_id": promoted["build_id"],
            "module_comparison": comparison,
        },
        "reproducibility": {
            "module_linkage": "deterministic for identical objects: unchanged-object modules must equal the promoted receipt",
            "raw_disk": "not bit-reproducible: ZFS snapshot/clone GUIDs, transaction groups, dataset and SMF repository timestamps and boot-archive contents depend on each native run",
        },
        "native_linkage": True,
        "guest_installation": True,
        "clean_export": True,
        "booted_kernel_validated": False,
        "firecracker_transport_validated": False,
        "native_services_validated": False,
        "native_admission": False,
    }
    options.output.mkdir(parents=True, exist_ok=True)
    for name, value in (("manifest.json", manifest), ("candidate-receipt.json", receipt)):
        (options.output / name).write_text(
            json.dumps(value, sort_keys=True, indent=2) + "\n", encoding="utf-8"
        )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("evidence", "kit", "disk", "reference", "output"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--build-id", required=True)
    check(parser.parse_args(namespace=Options()))


if __name__ == "__main__":
    main()
