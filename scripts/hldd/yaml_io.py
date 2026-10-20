"""Strict, batched YAML/frontmatter IO for standalone Elixir governance tools."""

import json
import os
import re
import sys
import tempfile
from pathlib import Path

import yaml
from yaml.events import AliasEvent
from yaml.nodes import MappingNode, Node, ScalarNode, SequenceNode

type Value = str | int | bool | list[Value] | dict[str, Value] | None


def value(node: Node) -> Value:
    """@cc [owner:ghuntley,label:verification] hldd-yaml-closed-values
    YAML MUST reject duplicate keys, non-string keys, custom tags and values
    outside the JSON data model rather than silently coerce review evidence.
    """
    if isinstance(node, MappingNode) and node.tag == "tag:yaml.org,2002:map":
        result: dict[str, Value] = {}
        for key_node, child in node.value:
            key = value(key_node)
            if not isinstance(key, str) or key in result:
                raise ValueError("YAML keys must be unique strings")
            result[key] = value(child)
        return result
    if isinstance(node, SequenceNode) and node.tag == "tag:yaml.org,2002:seq":
        return [value(child) for child in node.value]
    if isinstance(node, ScalarNode):
        if node.tag == "tag:yaml.org,2002:str":
            return node.value
        if node.tag == "tag:yaml.org,2002:null" and node.value in ("null", "~", ""):
            return None
        if node.tag == "tag:yaml.org,2002:bool" and node.value in ("true", "false"):
            return node.value == "true"
        if node.tag == "tag:yaml.org,2002:int" and re.fullmatch(r"-?(0|[1-9][0-9]*)", node.value):
            return int(node.value)
    raise ValueError("unsupported YAML value or tag")


def read(path: Path) -> dict[str, Value]:
    text = path.read_text(encoding="utf-8")
    body = ""
    if path.suffix == ".md":
        parts = text.split("\n---\n", 1)
        if not text.startswith("---\n") or len(parts) != 2:
            raise ValueError(f"missing frontmatter: {path}")
        text, body = parts[0][4:], parts[1].strip()
    for event in yaml.parse(text, Loader=yaml.CSafeLoader):
        if isinstance(event, AliasEvent) or getattr(event, "anchor", None) is not None:
            raise ValueError("YAML anchors and aliases are not supported")
    node = yaml.compose(text, Loader=yaml.CSafeLoader)
    if node is None:
        raise ValueError(f"empty YAML: {path}")
    return {"data": value(node), "body": body}


def write(path: Path, data: object, body: object) -> None:
    """@cc [owner:ghuntley,label:verification] hldd-yaml-atomic-write
    Writes MUST replace complete files atomically and leave identical files
    untouched. Review rationales MUST remain prose outside YAML frontmatter.
    """
    if not isinstance(body, str):
        raise ValueError("body must be text")
    text = yaml.dump(data, Dumper=yaml.CSafeDumper, allow_unicode=True, sort_keys=True, width=100)
    if path.suffix == ".md":
        text = "---\n" + text + "---\n\n" + body.strip() + "\n"
    if path.exists() and path.read_text(encoding="utf-8") == text:
        return
    path.parent.mkdir(parents=True, exist_ok=True)
    descriptor, temporary = tempfile.mkstemp(prefix=".hldd-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "w", encoding="utf-8") as output:
            output.write(text)
        os.replace(temporary, path)
    finally:
        Path(temporary).unlink(missing_ok=True)


def main() -> None:
    request: object = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    if not isinstance(request, dict):
        raise ValueError("expected request object")
    operation: object = request.get("operation")
    entries: object = request.get("entries")
    if not isinstance(entries, list):
        raise ValueError("expected entries")
    results: list[dict[str, Value]] = []
    for entry in entries:
        if not isinstance(entry, dict):
            raise ValueError("expected entry object")
        name: object = entry.get("path")
        if not isinstance(name, str):
            raise ValueError("expected path")
        path = Path(name)
        if operation == "read":
            results.append(read(path))
        elif operation == "write":
            write(path, entry.get("data"), entry.get("body", ""))
        else:
            raise ValueError("unknown operation")
    print(json.dumps(results))


if __name__ == "__main__":
    main()
