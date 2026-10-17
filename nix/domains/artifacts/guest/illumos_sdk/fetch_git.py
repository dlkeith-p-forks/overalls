"""Assemble pinned OmniOS Git builtins, HTTPS helpers, runtime libraries and trust."""

import json
import posixpath
import shlex
import sys
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path

from .fetch_sdk import Entry, fetch_file, parse_manifest, safe_path


def selected(path: str) -> bool:
    """Keep runtime paths; exclude headers, static archives, docs and services."""
    if path.endswith((".a", ".o")) or path.startswith(
        ("usr/lib/pkgconfig/", "usr/lib/amd64/pkgconfig/")
    ):
        return False
    return (
        path.startswith(
            (
                "lib/",
                "usr/lib/",
                "usr/gcc/",
                "usr/openssl/3/",
                "usr/libexec/amd64/git-core/",
                "usr/share/git-core/",
                "etc/ssl/",
                "etc/openssl/",
            )
        )
        or path == "usr/bin/git"
    )


def assemble(root: Path, manifests: list[Path]) -> None:
    """@cc [owner:ghuntley,label:build;security] illumos-git-runtime-closure
    Runtime bytes MUST come from exact reviewed official IPS manifests and pass
    compressed/plain digest and size checks. Extraction MUST preserve helper,
    interpreter, library and CA paths, reject conflicts/escaping links, and retain
    package identities. Package service actions and scripts MUST NOT execute.
    """
    packages = sorted(
        (parse_manifest(path, selected) for path in manifests), key=lambda package: package.fmri
    )
    paths: dict[str, Entry] = {}
    for package in packages:
        native_helpers: set[str] = set()
        for line in package.manifest.decode("utf-8").splitlines():
            fields = shlex.split(line)
            if fields and fields[0] == "file" and "elfbits=64" in fields:
                native_helpers.update(field[5:] for field in fields if field.startswith("path="))
        for entry in package.entries:
            if (
                entry.path.startswith("usr/libexec/amd64/git-core/")
                and entry.kind == "file"
                and entry.path not in native_helpers
            ):
                continue
            previous = paths.setdefault(entry.path, entry)
            if previous != entry:
                raise ValueError("conflicting runtime package path")
    for path, entry in tuple(paths.items()):
        if entry.kind == "hardlink" and entry.path.startswith("usr/libexec/amd64/git-core/"):
            resolved = posixpath.normpath(
                posixpath.join(posixpath.dirname(entry.path), entry.target)
            )
            if resolved not in paths:
                del paths[path]
    root.mkdir(parents=True, exist_ok=False)
    for package in packages:
        for line in package.manifest.decode("utf-8").splitlines():
            fields = shlex.split(line)
            if not fields or fields[0] != "dir":
                continue
            for field in fields[1:]:
                if field.startswith("path=") and selected(field[5:] + "/"):
                    (root / safe_path(field[5:])).mkdir(parents=True, exist_ok=True)
    entries = sorted(paths.values(), key=lambda entry: entry.path)
    with ThreadPoolExecutor(max_workers=16) as executor:
        records = list(
            executor.map(
                lambda entry: fetch_file(root, entry),
                [entry for entry in entries if entry.kind in ("file", "license")],
            )
        )
    for kind in ("link", "hardlink"):
        for entry in entries:
            if entry.kind != kind:
                continue
            target = root / entry.path
            target.parent.mkdir(parents=True, exist_ok=True)
            if kind == "link":
                target.symlink_to(entry.target)
            else:
                source = target.parent / entry.target
                if not source.is_file() or source.is_symlink():
                    raise ValueError("missing regular runtime hardlink target")
                target.hardlink_to(source)
    for entry in entries:
        if entry.kind in ("link", "hardlink") and not (root / entry.path).exists():
            raise ValueError(f"incomplete runtime link closure: {entry.path} -> {entry.target}")
    # SUNWcs normally installs this loader alias. Build the same guest-relative
    # link explicitly rather than executing a package installation script.
    loader = root / "usr/lib/amd64/ld.so.1"
    if not loader.exists():
        loader.parent.mkdir(parents=True, exist_ok=True)
        loader.symlink_to("../../../lib/amd64/ld.so.1")
    metadata = root / "share/overalls/native-git"
    metadata.mkdir(parents=True)
    for index, package in enumerate(packages):
        (metadata / f"manifest-{index}.p5m").write_bytes(package.manifest)
    provenance: dict[str, object] = {
        "version": 1,
        "release": "r151050",
        "status": "runtime-payload",
        "generated_links": {"usr/lib/amd64/ld.so.1": "../../../lib/amd64/ld.so.1"},
        "packages": [
            {"fmri": package.fmri, "sha256": package.manifest_digest} for package in packages
        ],
        "files": records,
    }
    (metadata / "provenance.json").write_text(json.dumps(provenance, sort_keys=True) + "\n")


def main(arguments: list[str]) -> None:
    if len(arguments) < 2:
        raise ValueError("expected OUTPUT MANIFEST...")
    assemble(Path(arguments[0]), [Path(value) for value in arguments[1:]])


if __name__ == "__main__":
    main(sys.argv[1:])
