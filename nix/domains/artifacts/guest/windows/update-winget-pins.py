"""Regenerate winget.json: the hash-pinned winget release and winget packages of Windows images.

Operator tool, run by hand and reviewed like any other pin change; the image
build never runs it and never reaches the network (`firmware-image-offline-assembly`).
Needs PyYAML (the repository's nixpkgs `python3.withPackages (p: [ p.pyyaml ])`).

    python3 update-winget-pins.py WINGET_TAG WINGET_PKGS_COMMIT ID[=VERSION] [ID[=VERSION] ...]

For the winget release it records the App Installer bundle, its license and
the framework-dependency archive with the SHA-256 digests GitHub publishes for
release assets. For each requested package (newest version at the commit
unless VERSION is given) and, recursively, each x64 package dependency its
installer declares, it records every manifest file of that version at the
given winget-pkgs commit (digest computed here) and the one x64 installer the
image installs, exactly as the installer manifest pins it. Packages are listed
dependencies first, which is the order the image installs them in.
"""

from __future__ import annotations

import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.request
from pathlib import Path
from typing import TypedDict

import yaml

WINGET_REPO = "microsoft/winget-cli"
PACKAGES_REPO = "microsoft/winget-pkgs"
BUNDLE = "Microsoft.DesktopAppInstaller_8wekyb3d8bbwe.msixbundle"
DEPENDENCIES = "DesktopAppInstaller_Dependencies.zip"
LICENSE_SUFFIX = "_License1.xml"
# Installer types winget runs with a machine-wide result, preferred over
# portable archives when a manifest offers both for x64.
PREFERRED_TYPES = ("msi", "wix", "burn", "inno", "nullsoft", "exe", "msix", "zip", "portable")


class Pinned(TypedDict):
    url: str
    sha256: str


class Winget(TypedDict):
    release: str
    bundle: Pinned
    license: Pinned
    dependencies: Pinned


class Installer(TypedDict):
    url: str
    sha256: str
    type: str
    scope: str | None


class Package(TypedDict):
    id: str
    version: str
    manifests: dict[str, Pinned]
    installer: Installer
    depends_on: list[str]


class Pins(TypedDict):
    winget: Winget
    source: dict[str, str]
    packages: list[Package]


GITHUB_HOSTS = ("https://api.github.com/", "https://raw.githubusercontent.com/")


def fetch(url: str) -> bytes:
    headers = {"User-Agent": "overalls-update-winget-pins"}
    # GitHub rate-limits anonymous API and raw requests; GITHUB_TOKEN (e.g.
    # from `gh auth token`) lifts that. Sent only to GitHub's own hosts.
    token = os.environ.get("GITHUB_TOKEN")
    if token and url.startswith(GITHUB_HOSTS):
        headers["Authorization"] = f"Bearer {token}"
    request = urllib.request.Request(url, headers=headers)
    for attempt in range(5):
        try:
            with urllib.request.urlopen(request, timeout=60) as response:
                body = response.read()
            break
        except urllib.error.HTTPError as error:
            if error.code != 429 or attempt == 4:
                raise
            time.sleep(15 * (attempt + 1))
    if not isinstance(body, bytes):
        raise TypeError(url)
    return body


def as_dict(value: object, what: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise TypeError(f"{what}: expected a mapping")
    return {str(key): item for key, item in value.items()}


def as_list(value: object, what: str) -> list[object]:
    if not isinstance(value, list):
        raise TypeError(f"{what}: expected a list")
    return list(value)


def as_str(value: object, what: str) -> str:
    if not isinstance(value, str):
        raise TypeError(f"{what}: expected a string")
    return value


def optional_str(value: object, what: str) -> str | None:
    return None if value is None else as_str(value, what)


def winget_release(tag: str) -> Winget:
    url = f"https://api.github.com/repos/{WINGET_REPO}/releases/tags/{tag}"
    release = as_dict(json.loads(fetch(url)), "release")
    assets: dict[str, Pinned] = {}
    for raw in as_list(release["assets"], "assets"):
        asset = as_dict(raw, "asset")
        name = as_str(asset["name"], "asset name")
        digest = as_str(asset.get("digest"), f"{name} digest")
        if not digest.startswith("sha256:"):
            raise ValueError(f"{name}: no sha256 digest published")
        assets[name] = Pinned(
            url=as_str(asset["browser_download_url"], name), sha256=digest.removeprefix("sha256:")
        )
    licenses = [name for name in assets if name.endswith(LICENSE_SUFFIX)]
    if len(licenses) != 1:
        raise ValueError(f"expected one license asset, found {licenses}")
    return Winget(
        release=tag,
        bundle=assets[BUNDLE],
        license=assets[licenses[0]],
        dependencies=assets[DEPENDENCIES],
    )


def package_path(package_id: str) -> str:
    publisher, name = package_id.split(".", 1)
    return f"manifests/{publisher[0].lower()}/{publisher}/{name.replace('.', '/')}"


def version_key(version: str) -> list[tuple[int, str]]:
    return [(int(part), "") if part.isdigit() else (-1, part) for part in version.split(".")]


def newest_version(commit: str, package_id: str) -> str:
    url = f"https://api.github.com/repos/{PACKAGES_REPO}/contents/{package_path(package_id)}?ref={commit}"
    names = [
        as_str(as_dict(entry, "entry")["name"], "name")
        for entry in as_list(json.loads(fetch(url)), "listing")
    ]
    versions = [name for name in names if name[:1].isdigit()]
    if not versions:
        raise ValueError(f"{package_id}: no versions at {commit}")
    return max(versions, key=version_key)


def choose_installer(document: dict[str, object], package_id: str) -> tuple[Installer, list[str]]:
    """The x64 installer the image installs and the package dependencies it declares.

    Root-level fields are defaults for every entry (winget manifest schema).
    Among x64 entries, an explicit machine scope wins, then the installer type
    order in PREFERRED_TYPES; two equally ranked distinct installers fail.
    """
    entries: list[dict[str, object]] = []
    for raw in as_list(document["Installers"], f"{package_id} Installers"):
        entry = {**document, **as_dict(raw, f"{package_id} installer")}
        if entry.get("Architecture") == "x64":
            entries.append(entry)
    if not entries:
        raise ValueError(f"{package_id}: no x64 installer")

    def rank(entry: dict[str, object]) -> tuple[int, int]:
        kind = str(entry.get("InstallerType", "")).lower()
        scope = entry.get("Scope")
        return (0 if scope == "machine" else 1 if scope is None else 2, PREFERRED_TYPES.index(kind))

    entries.sort(key=rank)
    best = entries[0]
    if (
        len(entries) > 1
        and rank(entries[1]) == rank(best)
        and entries[1]["InstallerUrl"] != best["InstallerUrl"]
    ):
        raise ValueError(f"{package_id}: ambiguous x64 installers")
    if best.get("Scope") == "user":
        raise ValueError(f"{package_id}: only user-scope x64 installers")
    dependencies = as_dict(best.get("Dependencies", {}), f"{package_id} Dependencies")
    depends_on = [
        as_str(as_dict(item, "dependency")["PackageIdentifier"], "dependency id")
        for item in as_list(dependencies.get("PackageDependencies", []), "PackageDependencies")
    ]
    installer = Installer(
        url=as_str(best["InstallerUrl"], f"{package_id} InstallerUrl"),
        sha256=as_str(best["InstallerSha256"], f"{package_id} InstallerSha256").lower(),
        type=as_str(best["InstallerType"], f"{package_id} InstallerType").lower(),
        scope=optional_str(best.get("Scope"), f"{package_id} Scope"),
    )
    return installer, depends_on


def package(commit: str, package_id: str, version: str) -> Package:
    path = f"{package_path(package_id)}/{version}"
    listing = json.loads(
        fetch(f"https://api.github.com/repos/{PACKAGES_REPO}/contents/{path}?ref={commit}")
    )
    manifests: dict[str, Pinned] = {}
    chosen: tuple[Installer, list[str]] | None = None
    for raw in as_list(listing, f"{package_id} listing"):
        name = as_str(as_dict(raw, "entry")["name"], "manifest name")
        url = f"https://raw.githubusercontent.com/{PACKAGES_REPO}/{commit}/{path}/{name}"
        body = fetch(url)
        manifests[name] = Pinned(url=url, sha256=hashlib.sha256(body).hexdigest())
        if name.endswith(".installer.yaml"):
            chosen = choose_installer(as_dict(yaml.safe_load(body), name), package_id)
    if chosen is None:
        raise ValueError(f"{package_id} {version}: no installer manifest")
    installer, depends_on = chosen
    return Package(
        id=package_id,
        version=version,
        manifests=manifests,
        installer=installer,
        depends_on=depends_on,
    )


def resolve(commit: str, requested: list[tuple[str, str | None]]) -> list[Package]:
    ordered: list[Package] = []
    seen: dict[str, Package] = {}
    visiting: set[str] = set()

    def visit(package_id: str, version: str | None) -> None:
        if package_id in seen:
            return
        if package_id in visiting:
            raise ValueError(f"dependency cycle through {package_id}")
        visiting.add(package_id)
        pinned = package(commit, package_id, version or newest_version(commit, package_id))
        for dependency in pinned["depends_on"]:
            visit(dependency, None)
        visiting.discard(package_id)
        seen[package_id] = pinned
        ordered.append(pinned)

    for package_id, version in requested:
        visit(package_id, version)
    return ordered


def main() -> None:
    if len(sys.argv) < 4:
        raise SystemExit(__doc__)
    tag, commit, *items = sys.argv[1:]
    requested = [
        (item.split("=", 1)[0], item.split("=", 1)[1] if "=" in item else None) for item in items
    ]
    pins = Pins(
        winget=winget_release(tag),
        source={"repository": PACKAGES_REPO, "commit": commit},
        packages=resolve(commit, requested),
    )
    out = Path(__file__).with_name("winget.json")
    out.write_text(json.dumps(pins, indent=2) + "\n")
    for pinned in pins["packages"]:
        installer = pinned["installer"]
        print(
            pinned["id"],
            pinned["version"],
            installer["type"],
            installer["scope"],
            pinned["depends_on"],
        )


if __name__ == "__main__":
    main()
