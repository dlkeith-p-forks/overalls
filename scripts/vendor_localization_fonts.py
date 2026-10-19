"""Rebuild the pinned, complete Noto web fonts; --check verifies vendored hashes."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import subprocess
import tempfile
import unicodedata
from dataclasses import dataclass
from pathlib import Path
from urllib.request import urlopen
from xml.etree import ElementTree

ROOT = Path(__file__).resolve().parents[1]
FONT_DIRECTORY = ROOT / "marshall/priv/static/fonts"
MANIFEST = FONT_DIRECTORY / "noto-fonts.json"


@dataclass(frozen=True)
class Font:
    file: str
    source_url: str
    source_sha256: str
    woff2_sha256: str
    license_file: str
    license_url: str
    license_sha256: str


def fields(value: object) -> dict[str, str]:
    if not isinstance(value, dict):
        raise ValueError("font entries must be objects")
    result: dict[str, str] = {}
    for key, item in value.items():
        if not isinstance(key, str) or not isinstance(item, str):
            raise ValueError("font fields must have string keys and values")
        result[key] = item
    return result


def fonts() -> list[Font]:
    value: object = json.loads(MANIFEST.read_text())
    if not isinstance(value, dict) or value.get("schema_version") != 1:
        raise ValueError("unsupported font manifest")
    entries: object = value.get("fonts")
    if not isinstance(entries, list):
        raise ValueError("font manifest must contain a font list")
    result = [Font(**fields(entry)) for entry in entries]
    for font in result:
        for name in (font.file, font.license_file):
            if Path(name).name != name:
                raise ValueError("font filenames must be local basenames")
        for url in (font.source_url, font.license_url):
            if not re.fullmatch(
                r"https://raw\.githubusercontent\.com/[^/]+/[^/]+/[0-9a-f]{40}/.+", url
            ):
                raise ValueError("font sources must name immutable upstream commits")
        for digest in (font.source_sha256, font.woff2_sha256, font.license_sha256):
            if not re.fullmatch(r"[0-9a-f]{64}", digest):
                raise ValueError("invalid SHA-256 digest")
    return result


def verify(path: Path, expected: str) -> None:
    if hashlib.sha256(path.read_bytes()).hexdigest() != expected:
        raise ValueError(f"SHA-256 mismatch: {path.name}")


def download(url: str, target: Path, expected: str) -> None:
    with urlopen(url, timeout=60) as response:
        target.write_bytes(response.read())
    verify(target, expected)


# @cc [owner:ghuntley,label:build;product] localization-font-reproduction
# Vendored fallback fonts MUST retain their complete upstream glyph/shaping
# tables and OFL notices. Source, licence and deterministic WOFF2 bytes MUST
# match the pinned manifest before replacing any served assets.
def rebuild(entries: list[Font]) -> None:
    with tempfile.TemporaryDirectory(prefix="overalls-fonts-") as directory:
        scratch = Path(directory)
        for font in entries:
            source = scratch / Path(font.source_url).name
            target = scratch / font.file
            license_path = scratch / font.license_file
            download(font.source_url, source, font.source_sha256)
            download(font.license_url, license_path, font.license_sha256)
            subprocess.run(
                ["fonttools", "ttLib.woff2", "compress", str(source), "-o", str(target)],
                check=True,
            )
            verify(target, font.woff2_sha256)

        for font in entries:
            (FONT_DIRECTORY / font.file).write_bytes((scratch / font.file).read_bytes())
            (FONT_DIRECTORY / font.license_file).write_bytes(
                (scratch / font.license_file).read_bytes()
            )


def cmap(font: Path, scratch: Path) -> set[int]:
    target = scratch / f"{font.stem}.ttx"
    subprocess.run(
        ["fonttools", "ttx", "-q", "-t", "cmap", "-o", str(target), str(font)], check=True
    )
    tree = ElementTree.parse(target)
    result: set[int] = set()
    for table in tree.findall("./cmap/*"):
        if table.tag == "cmap_format_14":
            continue
        platform = table.attrib.get("platformID")
        encoding = table.attrib.get("platEncID")
        if platform == "0" or (platform == "3" and encoding in {"1", "10"}):
            result.update(int(element.attrib["code"], 16) for element in table.findall("map"))
    return result


def visible(character: str) -> bool:
    point = ord(character)
    return (
        unicodedata.category(character) not in {"Cc", "Cf", "Cs", "Zl", "Zp"}
        and not 0xFE00 <= point <= 0xFE0F
        and not 0xE0100 <= point <= 0xE01EF
    )


# @cc [owner:ghuntley,label:verification;product] localized-visible-glyph-coverage
# Every visible catalog or supplied native-label codepoint MUST be present in
# the primary font or a fallback whose CSS Unicode range permits that codepoint.
# This check MUST NOT claim browser shaping or arbitrary user-content coverage.
def check_glyphs(extra_text: Path | None) -> None:
    with tempfile.TemporaryDirectory(prefix="overalls-glyphs-") as directory:
        scratch = Path(directory)
        available = cmap(FONT_DIRECTORY / "jetbrains-mono-500.woff2", scratch)
        css = (ROOT / "marshall/assets/css/fonts.css").read_text()
        for block in re.findall(r"@font-face\s*\{([^}]+)\}", css):
            source = re.search(r"url\(/fonts/(noto-[^)]+)\)", block)
            if source is None:
                continue
            permitted: set[int] = set()
            for start, end in re.findall(r"U\+([0-9A-F]+)(?:-([0-9A-F]+))?", block):
                permitted.update(range(int(start, 16), int(end or start, 16) + 1))
            available.update(cmap(FONT_DIRECTORY / source.group(1), scratch) & permitted)

        required: set[int] = set()
        units = 0
        for app in ("marshall", "porsche"):
            for catalog in (ROOT / app / "priv/gettext").glob("*/LC_MESSAGES/*.po"):
                for match in re.finditer(
                    r'(?m)^(?:msg(?:id(?:_plural)?|ctxt|str(?:\[\d+\])?) )?(".*")$',
                    catalog.read_text(),
                ):
                    value: object = json.loads(match.group(1))
                    if not isinstance(value, str):
                        raise ValueError("PO string unit must be text")
                    required.update(ord(character) for character in value if visible(character))
                    units += 1
        if extra_text is not None:
            required.update(
                ord(character) for character in extra_text.read_text() if visible(character)
            )
        missing = sorted(required - available)
        if missing:
            rendered = ", ".join(f"U+{point:04X}" for point in missing)
            raise ValueError(f"missing visible glyphs under CSS Unicode ranges: {rendered}")
        print(f"Verified {len(required):,} visible codepoints across {units:,} PO string units")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check", action="store_true", help="verify assets without network or tools"
    )
    parser.add_argument(
        "--check-glyphs", action="store_true", help="check catalogs with the fonttools executable"
    )
    parser.add_argument(
        "--text-file", type=Path, help="include UTF-8 text such as runtime CLDR native labels"
    )
    arguments = parser.parse_args()
    entries = fonts()
    if not arguments.check:
        rebuild(entries)
    for font in entries:
        verify(FONT_DIRECTORY / font.file, font.woff2_sha256)
        verify(FONT_DIRECTORY / font.license_file, font.license_sha256)
    if arguments.check_glyphs:
        extra_text: object = arguments.text_file
        if extra_text is not None and not isinstance(extra_text, Path):
            raise ValueError("additional text must be a file path")
        check_glyphs(extra_text)
    size = sum((FONT_DIRECTORY / font.file).stat().st_size for font in entries)
    print(f"Verified {len(entries)} complete fallback fonts ({size:,} bytes) and OFL notices")


if __name__ == "__main__":
    main()
