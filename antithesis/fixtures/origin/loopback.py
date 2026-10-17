"""Authenticated loopback OpenAI fixture for the integrated inner Ziggy role."""

import argparse
import hmac
import http.server
import signal
import stat
from pathlib import Path
from types import FrameType
from typing import NoReturn

from origin.server import OriginHandler, State


def read_key(path: Path) -> str:
    details = path.lstat()
    if (
        not stat.S_ISREG(details.st_mode)
        or details.st_nlink != 1
        or details.st_uid != 0
        or stat.S_IMODE(details.st_mode) != 0o600
        or not 16 <= details.st_size <= 4096
    ):
        raise ValueError("invalid loopback origin key file")
    key = path.read_text(encoding="ascii").strip()
    if len(key) < 16 or any(character.isspace() for character in key):
        raise ValueError("invalid loopback origin key")
    return key


class LoopbackHandler(OriginHandler):
    authorization: str = ""

    def _serve(self) -> None:
        """@cc [owner:ghuntley,label:security;verification] inner-origin-loopback-authority
        Only the fixed loopback endpoint with its private synthetic provider
        credential may reach the existing OpenAI fixture and durable receipts.
        """
        headers = self.headers.get_all("Authorization", [])
        hosts = self.headers.get_all("Host", [])
        if (
            self.client_address[0] != "127.0.0.1"
            or hosts != ["127.0.0.1:8080"]
            or len(headers) != 1
            or not self.authorization
            or not hmac.compare_digest(
                headers[0].encode("utf-8"), self.authorization.encode("ascii")
            )
        ):
            self.send_bytes(401, b"{}")
            return
        self.headers.replace_header("Host", "api.openai.com")
        super()._serve()


def terminate(_signum: int, _frame: FrameType | None) -> NoReturn:
    raise SystemExit(0)


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--state", type=Path, required=True)
    parser.add_argument("--key", type=Path, required=True)
    args = parser.parse_args()
    LoopbackHandler.authorization = "Bearer " + read_key(args.key)
    LoopbackHandler.state = State(args.state)
    signal.signal(signal.SIGTERM, terminate)
    with http.server.ThreadingHTTPServer(("127.0.0.1", 8080), LoopbackHandler) as server:
        server.serve_forever()


if __name__ == "__main__":
    main()
