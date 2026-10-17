"""Resolve Ubuntu packages with authenticated APT metadata; never install on the host."""

import argparse
import hashlib
import io
import json
import os
import re
import shutil
import subprocess
import tarfile
import tempfile
import urllib.request
from pathlib import Path
from typing import TypedDict
from urllib.parse import unquote

HERE = Path(__file__).resolve().parent


class Base(TypedDict):
    url: str
    sha256: str
    suite: str


def package_names(values: list[str]) -> list[str]:
    """@cc [owner:ghuntley,label:build] ubuntu-package-names
    Requests MUST be plain Ubuntu package names, never APT options, versions,
    paths or patterns. Versions and dependency identities belong in the lock.
    """
    if any(not isinstance(v, str) or not re.fullmatch(r"[a-z0-9][a-z0-9+.-]+", v) for v in values):
        raise ValueError("expected Ubuntu package names")
    return sorted(set(values))


def package_record(line: str) -> dict[str, str | int]:
    """Parse APT's authenticated download identity without accepting weak hashes."""
    match = re.fullmatch(r"'([^']+)' (\S+) ([0-9]+) SHA256:([0-9a-f]{64})", line)
    if not match:
        raise ValueError("APT returned a package without a SHA256 identity")
    url, filename, size, sha256 = match.groups()
    name, version, architecture = unquote(filename).removesuffix(".deb").split("_")
    package_names([name])
    if not url.startswith("https://snapshot.ubuntu.com/ubuntu/") or int(size) <= 0:
        raise ValueError("unexpected package source or size")
    if architecture not in ("amd64", "all") or not filename.endswith(".deb"):
        raise ValueError("unexpected package architecture")
    return {
        "name": name,
        "version": version,
        "architecture": architecture,
        "url": url,
        "filename": filename,
        "bytes": int(size),
        "sha256": sha256,
    }


def resolve(
    base: Base, requested: list[str], snapshot: str, apt_get: str, gpgv: str
) -> dict[str, object]:
    """@cc [owner:ghuntley,label:build] ubuntu-authenticated-resolution
    Resolution MUST use the hash-pinned base status and archive keyring, require
    signed snapshot metadata and SHA256 package identities, and only download
    metadata. It MUST NOT install packages or change the host APT configuration.
    """
    if not re.fullmatch(r"[0-9]{8}T[0-9]{6}Z", snapshot):
        raise ValueError("expected snapshot YYYYMMDDTHHMMSSZ")
    with urllib.request.urlopen(base["url"], timeout=120) as response:
        archive = response.read()
    if hashlib.sha256(archive).hexdigest() != base["sha256"]:
        raise ValueError("Ubuntu base checksum mismatch")
    with tempfile.TemporaryDirectory(prefix="ubuntu-lock-") as temporary:
        root = Path(temporary)
        with tarfile.open(fileobj=io.BytesIO(archive)) as source:
            for member, target in [
                ("var/lib/dpkg/status", "status"),
                ("usr/share/keyrings/ubuntu-archive-keyring.gpg", "archive.gpg"),
            ]:
                entries = {item.name.removeprefix("./"): item for item in source.getmembers()}
                content = source.extractfile(entries[member])
                if content is None:
                    raise ValueError("Ubuntu base archive member is not a regular file")
                (root / target).write_bytes(content.read())
        for directory in ["lists/partial", "archives/partial", "empty", "log"]:
            (root / directory).mkdir(parents=True)
        suites = " ".join(base["suite"] + suffix for suffix in ["", "-updates", "-security"])
        (root / "sources.sources").write_text(
            f"Types: deb\nURIs: https://snapshot.ubuntu.com/ubuntu/{snapshot}/\n"
            f"Suites: {suites}\nComponents: main universe restricted multiverse\n"
            f"Architectures: amd64\nSigned-By: {root}/archive.gpg\nCheck-Valid-Until: no\n"
        )
        settings = {
            "Dir": str(root),
            "Dir::State::status": str(root / "status"),
            "Dir::State::lists": str(root / "lists"),
            "Dir::Cache::archives": str(root / "archives"),
            "Dir::Etc::sourcelist": str(root / "sources.sources"),
            "Dir::Etc::sourceparts": str(root / "empty"),
            "Dir::Etc::parts": str(root / "empty"),
            "Dir::Etc::main": str(root / "absent"),
            "Dir::Etc::trustedparts": str(root / "empty"),
            "Dir::Etc::trusted": str(root / "archive.gpg"),
            "Dir::Bin::gpgv": gpgv,
            "APT::Key::gpgvcommand": gpgv,
            "APT::Architecture": "amd64",
            "APT::Architectures::": "amd64",
            "APT::Install-Recommends": "false",
            "APT::Install-Suggests": "false",
            "Acquire::ForceHash": "sha256",
            "Debug::NoLocking": "true",
            "APT::Get::List-Cleanup": "false",
            "APT::Update::Error-Mode": "any",
            "Dir::Cache::pkgcache": "",
            "Dir::Cache::srcpkgcache": "",
        }
        config = root / "apt.conf"
        config.write_text("\n".join(f'{key} "{value}";' for key, value in settings.items()))
        environment = {**os.environ, "APT_CONFIG": str(config), "LC_ALL": "C"}
        subprocess.run([apt_get, "update"], env=environment, check=True)
        result = subprocess.run(
            [apt_get, "--print-uris", "--yes", "--download-only", "install", *requested],
            env=environment,
            check=True,
            capture_output=True,
            text=True,
        )
        packages: list[dict[str, str | int]] = []
        for line in result.stdout.splitlines():
            if not line.startswith("'"):
                continue
            packages.append(package_record(line))
        if not packages:
            raise ValueError("empty package resolution")
        return {
            "version": 1,
            "base": base,
            "snapshot": snapshot,
            "requested": requested,
            "packages": sorted(packages, key=lambda p: p["filename"]),
        }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--snapshot", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--packages", nargs="*", default=[])
    args = parser.parse_args()
    base: Base = json.loads((HERE / "base.json").read_text())
    required = json.loads((HERE / "required-packages.json").read_text())
    apt_get = shutil.which("apt-get")
    gpgv = shutil.which("gpgv")
    assert apt_get is not None
    assert gpgv is not None
    lock = resolve(
        base,
        package_names(required + args.packages),
        args.snapshot,
        apt_get,
        gpgv,
    )
    # Atomic publication leaves the previous lock intact on fetch/verification failure.
    temporary = args.output.with_suffix(args.output.suffix + ".tmp")
    temporary.write_text(json.dumps(lock, indent=2) + "\n")
    temporary.replace(args.output)


if __name__ == "__main__":
    main()
