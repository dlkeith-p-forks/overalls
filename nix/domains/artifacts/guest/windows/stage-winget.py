"""Stage the pinned winget release and packages for an offline Windows installation.

Runs inside the Nix build on inputs Nix already fetched and verified against
winget.json. It writes:

  OUT/media/  copied to C:\\overalls\\winget by the boot media:
    Microsoft.DesktopAppInstaller.msixbundle, license.xml, dependencies\\*.appx
    (the x64 framework packages from the release's dependency archive),
    packages.txt (package ids in install order, dependencies first) and
    packages\\<id>\\*.yaml: the package's upstream manifests, with the installer
    manifest reduced to the single pinned x64 installer whose InstallerUrl
    points at the installation-only file server.
  OUT/serve/  installers at <sha256>/<upstream file name>, served to the
    installation guest by serve-pinned.py through QEMU guestfwd. winget names a
    download after the URL's last segment, which decides the extension it hands
    to msiexec and the command name of a portable package, so it is kept.

  With a Visual Studio layout (VS_LAYOUT_JSON, from update-vs-layout.ps1):
    OUT/media/vslayout/files.tsv  "<sha256>\t<layout path>" per file, served
      at <sha256>/f (a store symlink, so the 6 GB layout is not copied);
    OUT/media/vslayout/embedded/  the small files the layout generates;
    OUT/media/vslayout/intermediates/<sha256>.crt  certificates the offline
      chain needs (the installer's signer intermediate);
    OUT/media/vslayout/response.json  the layout's response file with the
      channel and catalog paths made absolute (C:\vslayout), because winget
      starts the bootstrapper outside the layout.

usage: stage-winget.py PINS_JSON FILES_JSON SERVER_URL OUT [VS_LAYOUT_JSON VS_FILES_JSON]

FILES_JSON maps every pinned URL to its fetched store path; VS_FILES_JSON maps
every Visual Studio layout digest to its fetched store path.
"""

from __future__ import annotations

import base64
import hashlib
import json
import shutil
import sys
import zipfile
from pathlib import Path
from typing import TypedDict

import yaml


class Pinned(TypedDict):
    url: str
    sha256: str


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


class Winget(TypedDict):
    release: str
    bundle: Pinned
    license: Pinned
    dependencies: Pinned


class Pins(TypedDict):
    winget: Winget
    source: dict[str, str]
    packages: list[Package]


def verified(files: dict[str, str], pinned: Pinned | Installer) -> Path:
    path = Path(files[pinned["url"]])
    digest = hashlib.sha256(path.read_bytes()).hexdigest()
    if digest != pinned["sha256"].lower():
        raise ValueError(f"{pinned['url']}: sha256 {digest} != {pinned['sha256']}")
    return path


def served_path(installer: Installer) -> str:
    name = installer["url"].rsplit("/", 1)[-1].split("?", 1)[0]
    if not name or not all(c.isalnum() or c in "._-+" for c in name):
        raise ValueError(f"{installer['url']}: unusable installer file name {name!r}")
    return f"{installer['sha256'].lower()}/{name}"


def reduce_installer(text: str, package: Package, server_url: str) -> str:
    document = yaml.safe_load(text)
    if not isinstance(document, dict):
        raise TypeError(f"{package['id']}: installer manifest is not a mapping")
    entries = [
        entry
        for entry in document["Installers"]
        if isinstance(entry, dict)
        and entry.get("InstallerUrl") == package["installer"]["url"]
        and {**document, **entry}.get("Architecture") == "x64"
        and {**document, **entry}.get("Scope") == package["installer"]["scope"]
    ]
    if len(entries) != 1:
        raise ValueError(f"{package['id']}: pinned installer matches {len(entries)} entries")
    entry = dict(entries[0])
    entry["InstallerUrl"] = f"{server_url}/{served_path(package['installer'])}"
    # The image installs every package machine-wide (`--scope machine`); an
    # unscoped upstream entry would be filtered out for MSI and exe types.
    if "Scope" not in entry and "Scope" not in document:
        entry["Scope"] = "machine"
    document["Installers"] = [entry]
    return yaml.safe_dump(document, sort_keys=False, allow_unicode=True)


def stage(pins: Pins, files: dict[str, str], server_url: str, out: Path) -> None:
    media = out / "media"
    serve = out / "serve"
    (media / "dependencies").mkdir(parents=True)
    (media / "packages").mkdir()
    serve.mkdir()
    winget = pins["winget"]
    shutil.copyfile(
        verified(files, winget["bundle"]), media / "Microsoft.DesktopAppInstaller.msixbundle"
    )
    shutil.copyfile(verified(files, winget["license"]), media / "license.xml")
    with zipfile.ZipFile(verified(files, winget["dependencies"])) as archive:
        x64 = [
            name
            for name in archive.namelist()
            if name.startswith("x64/") and name.endswith(".appx")
        ]
        if not x64:
            raise ValueError("dependency archive has no x64 framework packages")
        for name in x64:
            (media / "dependencies" / Path(name).name).write_bytes(archive.read(name))
    order: list[str] = []
    for package in pins["packages"]:
        target = media / "packages" / package["id"]
        target.mkdir()
        for name, pinned in package["manifests"].items():
            text = verified(files, pinned).read_text(encoding="utf-8")
            if name.endswith(".installer.yaml"):
                text = reduce_installer(text, package, server_url)
            (target / name).write_text(text, encoding="utf-8")
        served = serve / served_path(package["installer"])
        served.parent.mkdir(exist_ok=True)
        shutil.copyfile(verified(files, package["installer"]), served)
        order.append(package["id"])
    (media / "packages.txt").write_text("\r\n".join(order) + "\r\n", encoding="ascii")


LAYOUT_ROOT = "C:\\vslayout"


def sha256_file(path: Path) -> str:
    digest = hashlib.sha256()
    with path.open("rb") as source:
        while chunk := source.read(1 << 20):
            digest.update(chunk)
    return digest.hexdigest()


def safe_layout_path(path: str) -> str:
    parts = path.split("\\")
    if not path or any(part in ("", ".", "..") or ":" in part or "/" in part for part in parts):
        raise ValueError(f"unsafe layout path {path!r}")
    return path


def stage_vs_layout(layout: object, vs_files: dict[str, str], media: Path, serve: Path) -> None:
    raw = mapping(layout, "vs layout")
    target = media / "vslayout"
    (target / "embedded").mkdir(parents=True)
    (target / "intermediates").mkdir()
    lines: list[str] = []
    files = raw["files"]
    if not isinstance(files, list) or not files:
        raise TypeError("vs layout files: expected a non-empty list")
    for index, item in enumerate(files):
        entry = mapping(item, f"files[{index}]")
        sha = text(entry["sha256"], "sha256").lower()
        path = safe_layout_path(text(entry["path"], "path"))
        served = serve / sha / "f"
        if not served.exists():
            source = Path(vs_files[sha])
            if sha256_file(source) != sha:
                raise ValueError(f"{path}: fetched file does not match {sha}")
            served.parent.mkdir(exist_ok=True)
            served.symlink_to(source)
        lines.append(f"{sha}\t{path}")
    embedded = raw["embedded"]
    if not isinstance(embedded, list):
        raise TypeError("vs layout embedded: expected a list")
    response: dict[str, object] | None = None
    for index, item in enumerate(embedded):
        entry = mapping(item, f"embedded[{index}]")
        path = safe_layout_path(text(entry["path"], "path"))
        body = base64.b64decode(text(entry["content"], "content"))
        if hashlib.sha256(body).hexdigest() != text(entry["sha256"], "sha256").lower():
            raise ValueError(f"{path}: embedded content does not match its digest")
        destination = target / "embedded" / Path(*path.split("\\"))
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_bytes(body)
        if path == "Response.json":
            response = mapping(json.loads(body.decode("utf-8-sig")), "Response.json")
    if response is None:
        raise ValueError("vs layout has no Response.json")
    response["installChannelUri"] = f"{LAYOUT_ROOT}\\ChannelManifest.json"
    response["channelUri"] = f"{LAYOUT_ROOT}\\ChannelManifest.json"
    response["installCatalogUri"] = f"{LAYOUT_ROOT}\\Catalog.json"
    (target / "response.json").write_text(json.dumps(response, indent=2), encoding="utf-8")
    intermediates = raw.get("intermediates", [])
    if not isinstance(intermediates, list):
        raise TypeError("vs layout intermediates: expected a list")
    for index, item in enumerate(intermediates):
        entry = mapping(item, f"intermediates[{index}]")
        sha = text(entry["sha256"], "sha256").lower()
        source = Path(vs_files[sha])
        if sha256_file(source) != sha:
            raise ValueError(f"intermediate {sha} does not match")
        shutil.copyfile(source, target / "intermediates" / f"{sha}.crt")
    (target / "files.tsv").write_text("\r\n".join(lines) + "\r\n", encoding="utf-8")


def mapping(value: object, what: str) -> dict[str, object]:
    if not isinstance(value, dict):
        raise TypeError(f"{what}: expected a mapping")
    return {str(key): item for key, item in value.items()}


def text(value: object, what: str) -> str:
    if not isinstance(value, str):
        raise TypeError(f"{what}: expected a string")
    return value


def pinned(value: object, what: str) -> Pinned:
    raw = mapping(value, what)
    return Pinned(url=text(raw["url"], f"{what}.url"), sha256=text(raw["sha256"], f"{what}.sha256"))


def parse_pins(value: object) -> Pins:
    raw = mapping(value, "pins")
    winget = mapping(raw["winget"], "winget")
    packages: list[Package] = []
    items = raw["packages"]
    if not isinstance(items, list):
        raise TypeError("packages: expected a list")
    for index, item in enumerate(items):
        entry = mapping(item, f"packages[{index}]")
        installer = mapping(entry["installer"], f"packages[{index}].installer")
        scope = installer.get("scope")
        depends = entry.get("depends_on", [])
        if not isinstance(depends, list):
            raise TypeError(f"packages[{index}].depends_on: expected a list")
        packages.append(
            Package(
                id=text(entry["id"], "id"),
                version=text(entry["version"], "version"),
                manifests={
                    name: pinned(manifest, name)
                    for name, manifest in mapping(entry["manifests"], "manifests").items()
                },
                installer=Installer(
                    url=text(installer["url"], "installer.url"),
                    sha256=text(installer["sha256"], "installer.sha256"),
                    type=text(installer["type"], "installer.type"),
                    scope=None if scope is None else text(scope, "installer.scope"),
                ),
                depends_on=[text(dependency, "depends_on") for dependency in depends],
            )
        )
    return Pins(
        winget=Winget(
            release=text(winget["release"], "winget.release"),
            bundle=pinned(winget["bundle"], "winget.bundle"),
            license=pinned(winget["license"], "winget.license"),
            dependencies=pinned(winget["dependencies"], "winget.dependencies"),
        ),
        source={key: text(item, key) for key, item in mapping(raw["source"], "source").items()},
        packages=packages,
    )


def main() -> None:
    if len(sys.argv) not in (5, 7):
        raise SystemExit(__doc__)
    pins = parse_pins(json.loads(Path(sys.argv[1]).read_text()))
    files = {
        url: text(path, url)
        for url, path in mapping(json.loads(Path(sys.argv[2]).read_text()), "files").items()
    }
    out = Path(sys.argv[4])
    stage(pins, files, sys.argv[3].rstrip("/"), out)
    if len(sys.argv) == 7:
        layout = json.loads(Path(sys.argv[5]).read_text(encoding="utf-8-sig"))
        vs_files = {
            sha: text(path, sha)
            for sha, path in mapping(json.loads(Path(sys.argv[6]).read_text()), "vs files").items()
        }
        stage_vs_layout(layout, vs_files, out / "media", out / "serve")


if __name__ == "__main__":
    main()
