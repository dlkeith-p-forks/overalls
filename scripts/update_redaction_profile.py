#!/usr/bin/env python3
"""Generate Marshall's text-only redaction profile from pinned Gitleaks rules."""

from __future__ import annotations

import json
import pathlib
import re
import urllib.request

SOURCE = "https://raw.githubusercontent.com/gitleaks/gitleaks/master/config/gitleaks.toml"
TARGET = pathlib.Path("marshall/priv/redaction/profile.json")
# Keep this generator deterministic and fail closed if the upstream format changes.
RULE = re.compile(r'^\s*id\s*=\s*"([^"]+)"\s*$')
REGEX = re.compile(r"^\s*regex\s*=\s*(?:\"(.*)\"|'''(.*)''')\s*$")
BASE_RULES = [
    {"id": "github-token", "pattern": r"\bgh[pousr]_[A-Za-z0-9_]{20,}\b"},
    {"id": "openai-key", "pattern": r"\bsk-[A-Za-z0-9]{20,}\b"},
    {"id": "aws-access-key", "pattern": r"\bAKIA[0-9A-Z]{16}\b"},
    {
        "id": "private-key",
        "pattern": r"-----BEGIN(?: [A-Z0-9]+)* PRIVATE KEY-----.*?(?:-----END(?: [A-Z0-9]+)* PRIVATE KEY-----|$)",
    },
    {"id": "jwt", "pattern": r"\beyJ[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\.[A-Za-z0-9_-]{8,}\b"},
]


def main() -> None:
    text = urllib.request.urlopen(SOURCE, timeout=30).read().decode("utf-8")
    rules: list[dict[str, str]] = list(BASE_RULES)
    current: str | None = None
    for line in text.splitlines():
        match = RULE.match(line)
        if match:
            current = match.group(1)
            continue
        match = REGEX.match(line)
        if match and current:
            raw = match.group(1) if match.group(1) is not None else match.group(2)
            pattern = raw.replace('\\"', '"').replace("\\\\", "\\")
            if "attachment" not in current.lower() and "image" not in current.lower():
                rules.append({"id": current, "pattern": pattern})
            current = None
    if len(rules) < 5:
        raise RuntimeError(
            "upstream profile format changed; refusing to publish an incomplete profile"
        )
    payload = {"version": 1, "source": SOURCE, "rules": rules, "attachments": "excluded"}
    TARGET.write_text(json.dumps(payload, indent=2, sort_keys=True) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
