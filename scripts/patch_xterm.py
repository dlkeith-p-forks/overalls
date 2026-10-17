"""Check or reproduce the reviewed xterm accessibility patch from its official tarball."""

import argparse
import base64
import hashlib
import json
import tarfile
from dataclasses import dataclass
from pathlib import Path

VENDOR = Path(__file__).resolve().parent.parent / "marshall/assets/vendor/xterm"


@dataclass(frozen=True)
class Replacement:
    before: str
    after: str


@dataclass(frozen=True)
class Manifest:
    hashes: dict[str, str]
    replacements: tuple[Replacement, ...]


def manifest() -> Manifest:
    """Validate every external manifest field before applying bundle replacements."""
    value: object = json.loads((VENDOR / "accessibility-layout.json").read_text())
    if not isinstance(value, dict):
        raise ValueError("Expected an xterm patch manifest")
    keys = {
        "upstream_tarball_sha512",
        "upstream_esm_sha256",
        "upstream_source_sha256",
        "css_sha256",
        "license_sha256",
        "patched_esm_sha256",
    }
    if set(value) != keys | {"replacements"}:
        raise ValueError("Unexpected xterm patch manifest fields")
    hashes: dict[str, str] = {}
    for key in keys:
        item: object = value[key]
        if not isinstance(item, str) or not item:
            raise ValueError("Invalid xterm patch digest")
        hashes[key] = item
    raw_replacements: object = value["replacements"]
    if not isinstance(raw_replacements, list) or not raw_replacements:
        raise ValueError("Expected explicit xterm patch replacements")
    replacements: list[Replacement] = []
    for candidate in raw_replacements:
        row: object = candidate
        if not isinstance(row, dict) or set(row) != {"before", "after"}:
            raise ValueError("Invalid xterm patch replacement")
        before: object = row["before"]
        after: object = row["after"]
        if not isinstance(before, str) or not before or not isinstance(after, str) or not after:
            raise ValueError("Expected nonempty xterm patch replacement strings")
        replacements.append(Replacement(before, after))
    return Manifest(hashes, tuple(replacements))


def verify_digest(data: bytes, expected: str) -> None:
    if hashlib.sha256(data).hexdigest() != expected:
        raise ValueError("Unexpected xterm artifact digest")


def member(archive: tarfile.TarFile, name: str) -> bytes:
    source = archive.extractfile(name)
    if source is None:
        raise ValueError("Missing xterm tarball member")
    return source.read()


def reproduce(tarball: Path, output: Path, patch: Manifest) -> None:
    """@cc [owner:ghuntley,label:supply-chain] xterm-reviewed-reproduction
    Reproduction MUST verify official tarball integrity, original artifact hashes,
    exactly one occurrence of each replacement and the final bundle hash before
    writing output. It MUST NOT extract archive paths into the filesystem.
    """
    integrity = base64.b64encode(hashlib.sha512(tarball.read_bytes()).digest()).decode("ascii")
    if integrity != patch.hashes["upstream_tarball_sha512"]:
        raise ValueError("Unexpected xterm tarball integrity")
    with tarfile.open(tarball) as archive:
        esm = member(archive, "package/lib/xterm.mjs")
        verify_digest(esm, patch.hashes["upstream_esm_sha256"])
        verify_digest(member(archive, "package/css/xterm.css"), patch.hashes["css_sha256"])
        verify_digest(member(archive, "package/LICENSE"), patch.hashes["license_sha256"])
        verify_digest(
            member(archive, "package/src/browser/AccessibilityManager.ts"),
            patch.hashes["upstream_source_sha256"],
        )
    source = esm.decode("utf-8").replace("//# sourceMappingURL=xterm.mjs.map", "")
    for replacement in patch.replacements:
        if source.count(replacement.before) != 1:
            raise ValueError("Expected exactly one xterm patch target")
        source = source.replace(replacement.before, replacement.after)
    result = source.encode("utf-8")
    verify_digest(result, patch.hashes["patched_esm_sha256"])
    output.write_bytes(result)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    mode = parser.add_mutually_exclusive_group(required=True)
    mode.add_argument("--check", action="store_true")
    mode.add_argument("--tarball", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    patch = manifest()
    if args.check:
        if args.output is not None:
            parser.error("--output requires --tarball")
        for filename, key in (
            ("xterm.mjs", "patched_esm_sha256"),
            ("xterm.css", "css_sha256"),
            ("LICENSE", "license_sha256"),
        ):
            verify_digest((VENDOR / filename).read_bytes(), patch.hashes[key])
    else:
        if not isinstance(args.tarball, Path) or not isinstance(args.output, Path):
            parser.error("--tarball requires --output")
        reproduce(args.tarball, args.output, patch)
    print("Reviewed xterm patch verified.")


if __name__ == "__main__":
    main()
