"""Serve one HTTP/1.0 GET from a directory of pinned files over stdin/stdout.

QEMU's user-mode ``guestfwd=tcp:ADDR:PORT-cmd:...`` starts this program once per
guest connection with the connection on stdin and stdout. The installation
guest stays behind ``restrict=on``: this is its only reachable endpoint, and it
answers only for paths `/<directory>/<file>` naming a file one level below
the directory given as the single argument (the build's hash-pinned winget
installers, `<sha256>/<upstream file name>`). Anything else is a 404;
HEAD answers the same headers without a body; other methods are a 405.
libslirp hands the connection to this process as stdin, stdout *and* stderr,
so nothing may be printed: each request line and its status are appended to
LOG, a file in the build's working directory that the build keeps as
evidence. Nothing else is written.

usage: serve-pinned.py DIRECTORY LOG
"""

import contextlib
import os
import sys
from pathlib import Path
from typing import BinaryIO

MAX_REQUEST_BYTES = 8192
CHUNK_BYTES = 1 << 20


def read_request(stream: BinaryIO) -> bytes:
    data = b""
    while b"\r\n\r\n" not in data and len(data) < MAX_REQUEST_BYTES:
        # Unbuffered: one read(2) per call, so a short request never blocks.
        chunk = stream.read(MAX_REQUEST_BYTES - len(data))
        if not chunk:
            break
        data += chunk
    return data


LOG_PATH: Path | None = None


def log(request_line: str, status: str) -> None:
    if LOG_PATH is not None:
        with LOG_PATH.open("a", encoding="utf-8") as out:
            out.write(f"{request_line!r} {status}\n")


def respond(out: BinaryIO, status: str, length: int) -> None:
    head = f"HTTP/1.0 {status}\r\nContent-Length: {length}\r\nConnection: close\r\n"
    out.write((head + "Content-Type: application/octet-stream\r\n\r\n").encode())


def serve(root: Path, stdin: BinaryIO, stdout: BinaryIO) -> None:
    request = read_request(stdin)
    first = request.split(b"\r\n", 1)[0].decode("ascii", "replace")
    line = first.split(" ")
    if len(line) != 3 or line[0] not in ("GET", "HEAD"):
        log(first, "405")
        respond(stdout, "405 Method Not Allowed", 0)
        return
    parts = line[1].split("/")
    served = {
        (directory.name, entry.name)
        for directory in root.iterdir()
        if directory.is_dir()
        for entry in directory.iterdir()
        if entry.is_file()
    }
    if len(parts) != 3 or parts[0] != "" or (parts[1], parts[2]) not in served:
        log(first, "404")
        respond(stdout, "404 Not Found", 0)
        return
    path = root / parts[1] / parts[2]
    log(first, "200")
    respond(stdout, "200 OK", path.stat().st_size)
    if line[0] == "HEAD":
        stdout.flush()
        return
    with path.open("rb") as source:
        while chunk := source.read(CHUNK_BYTES):
            stdout.write(chunk)
    stdout.flush()


def main() -> None:
    global LOG_PATH
    if len(sys.argv) != 3:
        raise SystemExit("usage: serve-pinned.py DIRECTORY LOG")
    root = Path(sys.argv[1])
    LOG_PATH = Path(sys.argv[2])
    stdin = os.fdopen(sys.stdin.fileno(), "rb", buffering=0)
    stdout = os.fdopen(sys.stdout.fileno(), "wb")
    # The guest may close the connection early (winget retries).
    with contextlib.suppress(BrokenPipeError):
        serve(root, stdin, stdout)


if __name__ == "__main__":
    main()
