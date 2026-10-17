"""Wrong-kernel-UID socket fixture; no received bytes enter diagnostics."""

import os
import socket
from pathlib import Path


def main() -> None:
    assert os.getuid() == 0
    path = Path("/run/overalls-vscode/u200001/editor.sock")
    marker = Path("/run/editor-fixture-foreign-peer-received")
    assert path.parent.stat().st_uid == 200001
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as listener:
        listener.bind(str(path))
        os.chown(path, 200001, 200001)
        os.chmod(path, 0o600)
        listener.listen(16)
        for _ in range(1024):
            with listener.accept()[0] as stream:
                stream.settimeout(3)
                try:
                    received = stream.recv(1)
                except TimeoutError:
                    received = b""
                if received:
                    marker.touch(mode=0o600)


if __name__ == "__main__":
    main()
