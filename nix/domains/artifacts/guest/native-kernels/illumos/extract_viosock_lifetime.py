"""Extract the exact viosock attach/lifetime code for host fault injection."""

import re
import sys
from pathlib import Path


def declaration(source: str, prefix: str, *, semicolon: bool = False) -> str:
    """@cc [owner:ghuntley,label:verification] native-lifetime-test-source-extraction
    The test MUST compile actual maintained driver declarations and function
    bodies. Missing, duplicate or unclosed definitions MUST refuse extraction;
    copied substitutes MUST NOT establish the lifecycle regression result.
    """
    if source.count(prefix) != 1:
        raise ValueError(f"expected one definition of {prefix.strip()}")
    start = source.index(prefix)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    # These pinned declarations contain no brace-bearing strings or comments.
    while depth and end < len(source):
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    if depth or (semicolon and source[end : end + 1] != ";"):
        raise ValueError("unclosed viosock declaration")
    return source[start : end + int(semicolon)] + "\n"


def main(arguments: list[str]) -> None:
    if len(arguments) != 3:
        raise ValueError(
            "usage: extract_viosock_lifetime.py VIOSOCK_C SOCKVSOCK_C OUTPUT_DIRECTORY"
        )
    source = Path(arguments[0]).read_text()
    socket = Path(arguments[1]).read_text()
    output = Path(arguments[2])
    output.mkdir(parents=True, exist_ok=True)
    slots = re.findall(r"^#define OV_SLOTS ([1-9][0-9]*U)$", source, re.MULTILINE)
    if len(slots) != 1:
        raise ValueError("expected one bounded native slot-count definition")
    types = f"#define OV_SLOTS {slots[0]}\n"
    frame = re.findall(r"^#define OV_FRAME \([^\n]+\)$", source, re.MULTILINE)
    if len(frame) != 1:
        raise ValueError("expected one native frame-size definition")
    types += frame[0] + "\n"
    types += declaration(source, "struct ov_slot {", semicolon=True)
    types += declaration(source, "struct ov_device {", semicolon=True)
    functions = ""
    for prefix in (
        "static boolean_t\nov_slot_alloc(",
        "static void\nov_slot_free(",
        "static void\nov_destroy(",
        "static void\nov_retain_fenced(",
        "static int\nov_attach(",
        "static int\nov_detach(",
    ):
        functions += declaration(source, prefix)
    (output / "viosock_lifetime_types.inc").write_text(types)
    (output / "viosock_lifetime_functions.inc").write_text(functions)
    (output / "socket_handshake_types.inc").write_text(
        declaration(socket, "struct vs_socket {", semicolon=True)
    )
    (output / "socket_handshake_function.inc").write_text(
        declaration(socket, "static int\nvs_accept(")
    )


if __name__ == "__main__":
    main(sys.argv[1:])
