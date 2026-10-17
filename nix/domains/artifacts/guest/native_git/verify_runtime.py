"""Verify native Git ELF dependencies and report the pinned-base boundary."""

import json
import posixpath
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

FREEBSD_BASE = frozenset(
    (
        "libasn1.so.11",
        "libbsm.so.3",
        "libc++.so.1",
        "libc.so.7",
        "libcom_err.so.5",
        "libcrypt.so.5",
        "libcrypto.so.30",
        "libcxxrt.so.1",
        "libdl.so.1",
        "libedit.so.8",
        "libgcc_s.so.1",
        "libgssapi.so.10",
        "libgssapi_krb5.so.10",
        "libheimbase.so.11",
        "libheimntlm.so.11",
        "libhx509.so.11",
        "libkrb5.so.11",
        "liblzma.so.5",
        "libm.so.5",
        "libmd.so.6",
        "libncursesw.so.9",
        "libpam.so.6",
        "libroken.so.11",
        "librt.so.1",
        "libssl.so.30",
        "libthr.so.3",
        "libtinfow.so.9",
        "libutil.so.9",
        "libwind.so.11",
        "libz.so.6",
        "ld-elf.so.1",
    )
)


def elf_class(path: Path) -> int:
    if not path.is_file():
        return 0
    with path.open("rb") as source:
        header = source.read(20)
    if len(header) < 20 or header[:4] != b"\x7fELF":
        return 0
    if (
        header[4] not in (1, 2)
        or header[5] != 1
        or int.from_bytes(header[18:20], "little") != (3 if header[4] == 1 else 62)
    ):
        raise ValueError("unexpected runtime ELF architecture")
    return header[4]


@dataclass(frozen=True)
class Dynamic:
    needed: tuple[str, ...]
    interpreter: str | None
    runpaths: tuple[str, ...]


def dynamic(path: Path) -> Dynamic:
    output = subprocess.run(
        ["readelf", "--wide", "--dynamic", "--program-headers", str(path)],
        check=True,
        capture_output=True,
        text=True,
    ).stdout
    if "/nix/store/" in output or "ld-linux" in output:
        raise ValueError("foreign runtime ELF dependency")
    interpreter = re.search(r"\[Requesting program interpreter: ([^\]]+)\]", output)
    runpaths = re.findall(r"Library (?:runpath|rpath): \[([^\]]*)\]", output)
    needed = tuple(re.findall(r"\(NEEDED\).*Shared library: \[([^\]]+)\]", output))
    if any("/" in name or not name.isascii() for name in needed):
        raise ValueError("noncanonical runtime library name")
    return Dynamic(
        needed,
        interpreter[1] if interpreter else None,
        tuple(part for runpath in runpaths for part in runpath.split(":")),
    )


def dependency(
    root: Path, path: Path, width: int, name: str, description: Dynamic, os_name: str
) -> Path | None:
    """Resolve only declared runpaths and reviewed native default/cache paths."""
    defaults = (
        ("/lib", "/usr/lib", "/usr/local/lib")
        if os_name == "freebsd"
        else (("/lib/amd64", "/usr/lib/amd64") if width == 2 else ("/lib", "/usr/lib"))
    )
    origin = "/" + str(path.parent.relative_to(root))
    for runpath in (*description.runpaths, *defaults):
        expanded = runpath.replace("${ORIGIN}", origin).replace("$ORIGIN", origin)
        if not expanded.startswith("/") or "$" in expanded:
            raise ValueError("unsupported native library runpath")
        candidate = root / posixpath.normpath(expanded).removeprefix("/") / name
        if not candidate.resolve().is_relative_to(root.resolve()):
            raise ValueError("runtime library escapes payload")
        if elf_class(candidate) == width:
            return candidate
    return None


def prune_illumos(root: Path) -> None:
    """Retain the Git/HTTPS and NSS/crypto/charset plugin ELF dependency closure."""
    pending: list[Path] = []
    all_elf: list[Path] = []
    for path in sorted(root.rglob("*")):
        width = elf_class(path)
        if not width:
            continue
        all_elf.append(path)
        relative = str(path.relative_to(root))
        if width == 2 and (
            relative == "usr/bin/git"
            or relative.startswith("usr/libexec/amd64/git-core/")
            or "/ossl-modules/" in relative
            or "/iconv/" in relative
            or path.name in ("nss_dns.so.1", "nss_files.so.1")
        ):
            pending.append(path)
    retained: set[Path] = set()
    while pending:
        path = pending.pop()
        actual = path.resolve(strict=True)
        if actual in retained:
            continue
        retained.add(actual)
        width = elf_class(path)
        description = dynamic(path)
        if description.interpreter:
            interpreter = root / description.interpreter.removeprefix("/")
            if elf_class(interpreter) != width:
                raise ValueError("missing selected illumos interpreter")
            pending.append(interpreter)
        for name in description.needed:
            target = dependency(root, path, width, name, description, "illumos")
            if target is None:
                raise ValueError(
                    f"missing selected illumos dependency {name} for {path.relative_to(root)}"
                )
            pending.append(target)
    removable = [path for path in all_elf if path.resolve(strict=True) not in retained]
    for path in removable:
        path.unlink()
    for path in root.rglob("*"):
        if path.is_symlink() and not path.exists():
            path.unlink()


def verify(os_name: str, root: Path) -> None:
    """@cc [owner:ghuntley,label:build;verification] native-git-runtime-dependencies
    Every selected ELF interpreter and DT_NEEDED library MUST resolve to the
    payload at the required ELF width or the explicit pinned FreeBSD base list.
    Linux interpreters and Nix paths MUST refuse. Recorded base dependencies are
    installation requirements; ELF inspection MUST NOT claim guest execution.
    """
    if os_name not in ("freebsd", "illumos"):
        raise ValueError("unknown native family")
    for path in root.rglob("*"):
        if path.is_symlink() and not path.resolve().is_relative_to(root.resolve()):
            raise ValueError("runtime link escapes payload")
    if os_name == "illumos":
        prune_illumos(root)
    executable = root / ("usr/local/bin/git" if os_name == "freebsd" else "usr/bin/git")
    helper = root / (
        "usr/local/libexec/git-core/git-remote-https"
        if os_name == "freebsd"
        else "usr/libexec/amd64/git-core/git-remote-https"
    )
    trust = root / ("etc/ssl/cert.pem" if os_name == "freebsd" else "etc/ssl/cacert.pem")
    if elf_class(executable) != 2 or elf_class(helper) != 2 or not trust.is_file():
        raise ValueError("missing Git, HTTPS helper or trust bundle")
    for path in root.rglob("*"):
        if path.is_symlink() and not path.exists():
            raise ValueError("runtime link is unresolved")
    binaries: list[tuple[Path, int]] = []
    for path in sorted(root.rglob("*")):
        width = elf_class(path)
        if width and not path.is_symlink():
            binaries.append((path, width))
    base: set[str] = set()
    for path, width in binaries:
        description = dynamic(path)
        if description.interpreter:
            target = description.interpreter
            expected = (
                "/libexec/ld-elf.so.1"
                if os_name == "freebsd"
                else ("/usr/lib/amd64/ld.so.1" if width == 2 else "/usr/lib/ld.so.1")
            )
            if target != expected:
                raise ValueError("unexpected native interpreter")
            if not (root / target.removeprefix("/")).is_file():
                if os_name != "freebsd":
                    raise ValueError("missing native interpreter")
                base.add(target)
        for name in description.needed:
            if dependency(root, path, width, name, description, os_name) is not None:
                continue
            if os_name != "freebsd" or width != 2 or name not in FREEBSD_BASE:
                raise ValueError(
                    f"missing {os_name} runtime library {name} for {path.relative_to(root)}"
                )
            base.add(name)
    metadata: dict[str, object] = {
        "version": 1,
        "os": os_name,
        "elf_files": len(binaries),
        "base_dependencies": sorted(base),
        "library_cache_paths": ["/usr/local/lib"] if os_name == "freebsd" else [],
        "runtime_verified": False,
        "git": "/" + str(executable.relative_to(root)),
        "https_helper": "/" + str(helper.relative_to(root)),
        "trust": "/" + str(trust.relative_to(root)),
    }
    destination = root / "share/overalls/native-git/elf-dependencies.json"
    destination.write_text(json.dumps(metadata, sort_keys=True) + "\n")
    print(json.dumps(metadata, sort_keys=True))


def main(arguments: list[str]) -> None:
    if len(arguments) != 2:
        raise ValueError("expected FAMILY ROOT")
    verify(arguments[0], Path(arguments[1]))


if __name__ == "__main__":
    main(sys.argv[1:])
