"""Unprivileged native channel tests; synthetic workers do not prove ZFS/SSH behavior."""

import array
import base64
import os
import pwd
import shutil
import socket
import struct
import subprocess
import sys
import tempfile
import time
import unittest
from typing import IO, cast

HELPER: str = sys.argv.pop(1)
KEY = base64.b64encode(
    struct.pack("!I", 11) + b"ssh-ed25519" + struct.pack("!I", 32) + bytes(32)
).decode()
COMMAND = "lilly-export-v4 aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"


class ChannelTest(unittest.TestCase):
    def setUp(self) -> None:
        self.root = tempfile.TemporaryDirectory()
        self.addCleanup(self.root.cleanup)
        self.processes = []
        self.addCleanup(self.cleanup_processes)
        self.path = self.root.name + "/socket"
        self.listener = socket.socket(socket.AF_UNIX)
        self.listener.bind(self.path)
        self.listener.listen(1)
        self.listener.settimeout(5)
        self.addCleanup(self.listener.close)
        # Closed through addCleanup, matching the other per-test resources.
        self.output = tempfile.TemporaryFile()  # noqa: SIM115
        self.addCleanup(self.output.close)

    def cleanup_processes(self) -> None:
        for process in self.processes:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            if process.stderr:
                process.stderr.close()

    def worker(self, body: str) -> str:
        path = self.root.name + "/worker"
        python = shutil.which("python3")
        assert python is not None
        with open(path, "w") as f:
            f.write("#!" + python + "\n" + body)
        os.chmod(path, 0o700)
        return path

    def server(
        self, connection: socket.socket, worker: str, account: str | None = None
    ) -> subprocess.Popen[bytes]:
        # subprocess accepts any fd-backed object for stdin; typeshed models
        # only int | IO, so cast the connected AF_UNIX socket at this boundary.
        process = subprocess.Popen(
            [HELPER, "serve", account or pwd.getpwuid(os.getuid()).pw_name, worker],
            stdin=cast("IO[bytes] | int", connection),
            stdout=subprocess.DEVNULL,
            stderr=subprocess.PIPE,
        )
        self.processes.append(process)
        connection.close()
        return process

    def bridge(self, command: str = COMMAND) -> tuple[subprocess.Popen[bytes], socket.socket]:
        process = subprocess.Popen(
            [HELPER, "bridge", self.path, KEY],
            stdout=self.output,
            stderr=subprocess.PIPE,
            env=dict(os.environ, SSH_ORIGINAL_COMMAND=command),
        )
        self.processes.append(process)
        connection, _ = self.listener.accept()
        return process, connection

    def wait_file(self, name: str) -> str:
        path = self.root.name + "/" + name
        deadline = time.monotonic() + 5
        while not os.path.exists(path):
            self.assertLess(time.monotonic(), deadline)
            time.sleep(0.01)
        with open(path) as f:
            return f.read()

    def test_data_is_separate_and_identity_is_fixed(self) -> None:
        worker = self.worker(
            "import os,sys\n"
            f'assert os.environ["LILLY_EXPORT_KEY"] == {KEY!r}\n'
            f'assert os.environ["LILLY_EXPORT_REQUEST"] == {COMMAND!r}\n'
            'assert sys.stdin.buffer.read() == b""\n'
            "sys.stdout.buffer.write(bytes(range(256)) * 4096)\n"
        )
        bridge, connection = self.bridge()
        server = self.server(connection, worker)
        self.assertEqual(bridge.wait(timeout=10), 0)
        self.assertEqual(server.wait(timeout=5), 0)
        self.output.seek(0)
        self.assertEqual(self.output.read(), bytes(range(256)) * 4096)
        assert server.stderr is not None
        self.assertEqual(server.stderr.read(), b"")

    def test_bounded_resume_request_crosses_channel_without_diagnostics(self) -> None:
        command = "lilly-resume-v4 aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa 1-a-10-" + "ab" * 4092
        worker = self.worker(
            f'import os\nassert os.environ["LILLY_EXPORT_REQUEST"] == {command!r}\n'
        )
        bridge, connection = self.bridge(command)
        server = self.server(connection, worker)
        self.assertEqual(bridge.wait(timeout=10), 0)
        self.assertEqual(server.wait(timeout=5), 0)
        assert server.stderr is not None
        self.assertEqual(server.stderr.read(), b"")
        assert bridge.stderr is not None
        self.assertEqual(bridge.stderr.read(), b"")
        self.output.seek(0)
        self.assertEqual(self.output.read(), b"")

    def test_complete_bytes_with_failed_worker_are_not_success(self) -> None:
        bridge, connection = self.bridge()
        server = self.server(
            connection,
            self.worker('import sys\nsys.stdout.buffer.write(b"complete")\nsys.exit(7)\n'),
        )
        self.assertEqual(bridge.wait(timeout=5), 1)
        self.assertEqual(server.wait(timeout=5), 1)
        self.output.seek(0)
        self.assertEqual(self.output.read(), b"complete")

    def test_channel_eof_is_not_success(self) -> None:
        bridge, connection = self.bridge()
        connection.close()
        self.assertEqual(bridge.wait(timeout=5), 1)

    def test_bridge_death_reaps_worker_and_child(self) -> None:
        pids = self.root.name + "/pids"
        body = (
            "import os,subprocess,time\n"
            f'child=subprocess.Popen([{shutil.which("sleep")!r}, "30"])\n'
            f'open({pids!r}, "w").write(str(os.getpid())+" "+str(child.pid))\n'
            "time.sleep(30)\n"
        )
        bridge, connection = self.bridge()
        server = self.server(connection, self.worker(body))
        running = self.wait_file("pids").split()
        bridge.kill()
        bridge.wait(timeout=5)
        self.assertEqual(server.wait(timeout=5), 1)
        for pid in running:
            self.assertFalse(os.path.exists("/proc/" + pid))

    def test_wrong_peer_cannot_launch_worker(self) -> None:
        other = next(entry.pw_name for entry in pwd.getpwall() if entry.pw_uid != os.getuid())
        bridge, connection = self.bridge()
        marker = self.root.name + "/ran"
        server = self.server(
            connection, self.worker(f'open({marker!r}, "w").write("ran")\n'), other
        )
        self.assertEqual(server.wait(timeout=5), 1)
        self.assertEqual(bridge.wait(timeout=5), 1)
        self.assertFalse(os.path.exists(marker))

    def test_malformed_frames_and_descriptors_do_not_launch(self) -> None:
        marker = self.root.name + "/ran"
        worker = self.worker(f'open({marker!r}, "w").write("ran")\n')
        frame = struct.pack(
            "!4sHH128s8320s", b"LEX3", len(KEY), len(COMMAND), KEY.encode(), COMMAND.encode()
        )
        with open("/dev/null", "rb") as readonly:
            for payload, fds in [
                (b"bad", [self.output.fileno()]),
                (frame, []),
                (frame, [self.output.fileno(), self.output.fileno()]),
                (frame, [readonly.fileno()]),
                (frame[:-1] + b"x", [self.output.fileno()]),
            ]:
                with self.subTest(fds=len(fds), size=len(payload)):
                    client = socket.socket(socket.AF_UNIX)
                    self.addCleanup(client.close)
                    client.connect(self.path)
                    connection, _ = self.listener.accept()
                    server = self.server(connection, worker)
                    ancillary = (
                        [(socket.SOL_SOCKET, socket.SCM_RIGHTS, array.array("i", fds))]
                        if fds
                        else []
                    )
                    client.sendmsg([payload], ancillary)
                    client.shutdown(socket.SHUT_WR)
                    self.assertEqual(server.wait(timeout=5), 1)
                    client.close()
                    self.assertFalse(os.path.exists(marker))


if __name__ == "__main__":
    unittest.main()
