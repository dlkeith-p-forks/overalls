"""Extract pinned, patched kernel functions for the host regression harnesses."""

import re
import sys
from pathlib import Path


def extract_function(source: str, signature: str, declaration: str) -> str:
    """@cc [owner:ghuntley,label:verification] native-listener-test-source-extraction
    The harness MUST execute function bodies and flag values read from the patched
    pinned kernel source. Extraction MUST fail on a missing or ambiguous definition;
    manually copied or rewritten implementations MUST NOT satisfy this check.
    """
    needle = declaration + signature
    if source.count(needle) != 1:
        raise ValueError(f"expected one function definition for {signature}")
    start = source.index(needle)
    brace = source.index("{", start)
    depth = 1
    end = brace + 1
    # These pinned functions contain no brace-bearing string literals or
    # comments. An unmatched body is rejected instead of emitting partial C.
    while depth and end < len(source):
        depth += (source[end] == "{") - (source[end] == "}")
        end += 1
    if depth:
        raise ValueError(f"unclosed function body for {signature}")
    return source[start:end] + "\n"


def main(arguments: list[str]) -> None:
    if len(arguments) != 2:
        raise ValueError("usage: extract_listener_reset.py PATCHED_SOURCE OUTPUT_DIRECTORY")
    source = Path(arguments[0]) / "usr/src/uts/common"
    output = Path(arguments[1])
    output.mkdir(parents=True, exist_ok=True)
    functions = extract_function(
        (source / "fs/sockfs/sockcommon_subr.c").read_text(),
        "so_acceptq_dequeue_locked(",
        "static int\n",
    )
    functions += extract_function(
        (source / "fs/sockfs/sockcommon_sops.c").read_text(),
        "so_disconnected(sock_upper_handle_t",
        "int\n",
    )
    header = (source / "sys/socketvar.h").read_text()
    flags = ""
    for name in (
        "SM_LISTENERR",
        "SS_ISCONNECTED",
        "SS_ACCEPTCONN",
        "SS_LISTENERR",
        "SS_CLOSING",
        "SS_FALLBACK_PENDING",
    ):
        matches = re.findall(
            rf"^#define[ \t]+{name}[ \t]+(0x[0-9a-fA-F]+)(?:[ \t]|$)",
            header,
            re.MULTILINE,
        )
        if len(matches) != 1:
            raise ValueError(f"expected one numeric definition for {name}")
        flags += f"#define {name} {matches[0]}U\n"
    (output / "listener_reset_flags.inc").write_text(flags)
    (output / "listener_reset_functions.inc").write_text(functions)
    block = (source / "io/vioblk/vioblk.c").read_text()
    (output / "block_budget_function.inc").write_text(
        extract_function(block, "vioblk_request_capacity(", "static uint_t\n")
    )
    definitions = re.findall(
        r"^#define[ \t]+VIRTIO_BLK_REQ_BUFS[ \t]+([0-9]+)(?:[ \t]|$)",
        (source / "io/vioblk/vioblk.h").read_text(),
        re.MULTILINE,
    )
    if len(definitions) != 1:
        raise ValueError("expected one numeric definition for VIRTIO_BLK_REQ_BUFS")
    (output / "block_budget_limit.inc").write_text(
        f"#define VIRTIO_BLK_REQ_BUFS {definitions[0]}U\n"
    )
    (output / "net_receive_budget_function.inc").write_text(
        extract_function(
            (source / "io/vioif/vioif.c").read_text(),
            "vioif_rx_loan_limit(",
            "static uint_t\n",
        )
    )
    completion = ""
    for name, declaration in (
        ("vioblk_req_alloc(", "static vioblk_req_t *\n"),
        ("vioblk_req_free(", "static void\n"),
        ("vioblk_complete(", "static int\n"),
        ("vioblk_common_submit(", "static int\n"),
        ("vioblk_poll(", "static uint_t\n"),
    ):
        completion += extract_function(block, name, declaration)
    (output / "block_completion_functions.inc").write_text(completion)
    (output / "block_completion_types.inc").write_text(block_completion_types(source))


def block_completion_types(source: Path) -> str:
    """@cc [owner:ghuntley,label:verification] native-block-completion-source-extraction
    The reentrant completion harness MUST compile the actual request layout,
    status flags, command/status constants and five patched driver functions.
    Missing or ambiguous definitions MUST refuse instead of using substitutes.
    """
    header = (source / "io/vioblk/vioblk.h").read_text()
    result = ""
    for pattern in (
        r"struct vioblk_req_hdr \{[^}]+\} __packed;",
        r"typedef enum vioblk_req_status \{[^}]+\} vioblk_req_status_t;",
        r"typedef struct vioblk_req \{[^}]+\} vioblk_req_t;",
    ):
        matches = re.findall(pattern, header)
        if len(matches) != 1:
            raise ValueError("expected one native block request declaration")
        result += matches[0] + "\n"
    for name in (
        "VIRTIO_BLK_T_OUT",
        "VIRTIO_BLK_T_FLUSH",
        "VIRTIO_BLK_T_GET_ID",
        "VIRTIO_BLK_S_OK",
        "VIRTIO_BLK_S_IOERR",
        "VIRTIO_BLK_S_UNSUPP",
    ):
        matches = re.findall(
            rf"^#define[ \t]+{name}[ \t]+([0-9]+)(?:[ \t]|$)", header, re.MULTILINE
        )
        if len(matches) != 1:
            raise ValueError(f"expected one numeric definition for {name}")
        result += f"#define {name} {matches[0]}\n"
    return result


if __name__ == "__main__":
    main(sys.argv[1:])
