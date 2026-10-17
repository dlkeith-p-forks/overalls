"""Fresh DNS evidence from the owning host, fenced to a child-created offer."""

import base64
import json
import os
import re
import secrets
import socket
import stat
import time
from pathlib import Path
from typing import TYPE_CHECKING, NotRequired, TypedDict

from runtime import SetupError, encode, publish, read_private

if TYPE_CHECKING:
    import ingress

UUID = re.compile(r"[0-9a-f]{8}(?:-[0-9a-f]{4}){3}-[0-9a-f]{12}")
LABEL = re.compile(r"[a-z][a-z0-9-]*-[0-9a-f]{32}")
SHARED = Path("/run/inception-proofs")


class Binding(TypedDict):
    placement_id: str
    execution_epoch: int
    boot_challenge: str


class Record(TypedDict):
    label: str
    proofs: list[str]
    ttl_ms: int


class Observations(TypedDict):
    request_id: str
    records: list[Record]


class Request(TypedDict):
    binding: Binding
    request_id: str
    generation: int
    public: NotRequired["ingress.Public"]
    observations: NotRequired[Observations | None]


class ReplyRecord(TypedDict):
    label: str
    proofs: list[str]


class Reply(TypedDict):
    ttl_ms: int
    records: list[ReplyRecord]


class Offer(TypedDict):
    binding: Binding
    generation: int
    request_id: str
    created_at_ms: int
    expires_at_ms: int
    proofs: dict[str, list[str]]


class EvidenceRecord(TypedDict):
    label: str
    proofs: list[str]
    expires_at_ms: int


class Evidence(TypedDict):
    binding: Binding
    generation: int
    records: list[EvidenceRecord]


class Query(TypedDict):
    version: int
    binding: Binding
    generation: int
    label: str
    proofs: list[str]


def proof(value: object) -> bool:
    if not isinstance(value, str) or len(value) != 43:
        return False
    try:
        raw = base64.b64decode(value + "=", altchars=b"-_", validate=True)
        return len(raw) == 32 and base64.urlsafe_b64encode(raw).decode().rstrip("=") == value
    except ValueError:
        return False


def validate(value: Observations | None) -> Observations | None:
    if value is None:
        return None
    if (
        not isinstance(value, dict)
        or set(value) != {"request_id", "records"}
        or not isinstance(value["request_id"], str)
        or not UUID.fullmatch(value["request_id"])
        or not isinstance(value["records"], list)
        or len(value["records"]) > 16
        or not all(isinstance(item, dict) for item in value["records"])
    ):
        raise SetupError("DNS observations invalid")
    seen = set()
    for item in value["records"]:
        if (
            not isinstance(item, dict)
            or set(item) != {"label", "proofs", "ttl_ms"}
            or not isinstance(item["label"], str)
            or not (
                item["label"] == "control"
                or (34 <= len(item["label"]) <= 63 and LABEL.fullmatch(item["label"]))
            )
            or item["label"] in seen
            or type(item["ttl_ms"]) is not int
            or not 1 <= item["ttl_ms"] <= 5000
            or not isinstance(item["proofs"], list)
            or not 1 <= len(item["proofs"]) <= 2
            or not all(proof(p) for p in item["proofs"])
            or len(set(item["proofs"])) != len(item["proofs"])
        ):
            raise SetupError("DNS observations invalid")
        seen.add(item["label"])
    return value


def remember(value: Request, reply: Reply, root: Path, started: int) -> None:
    """@cc [owner:ghuntley,label:security] inception-proof-offer-source-lifetime
    A proof offer MUST capture this reply's exact boot, generation and proof sets.
    Its deadline MUST derive from publication sampling time and remaining source
    TTL. A later host receipt MUST NOT create or extend the offer's lifetime.
    """
    if value.get("public") is None:
        (root / "proof-offer.json").unlink(missing_ok=True)
        return
    offer: Offer = {
        "binding": value["binding"],
        "generation": value["generation"],
        "request_id": value["request_id"],
        "created_at_ms": started,
        "expires_at_ms": started + reply["ttl_ms"],
        "proofs": {
            record["label"]: sorted(record["proofs"])
            for record in reply["records"]
            if record["proofs"]
        },
    }
    publish(root / "proof-offer.json", encode(offer))


def accept(
    value: Request,
    root: Path,
    shared: Path = SHARED,
    current: int | None = None,
) -> None:
    """@cc [owner:ghuntley,label:security;recovery] inception-observation-offer-fence
    Host evidence MUST consume one unexpired offer for the exact boot/generation
    and exact offered proof sets. Expiry MUST be capped from offer creation, not
    receipt. Missing, replayed, stale or changed evidence MUST grant no authority.
    The Audi-readable result MUST remain root-owned and not group-writable.
    """
    evidence = validate(value.get("observations"))
    if evidence is None:
        return
    current = time.monotonic_ns() // 1000000 if current is None else current
    path = root / "proof-offer.json"
    offer: Offer = json.loads(read_private(path))
    if (
        value.get("public") is None
        or offer["binding"] != value["binding"]
        or offer["generation"] != value["generation"]
        or offer["request_id"] != evidence["request_id"]
        or not offer["created_at_ms"]
        <= current
        < offer["expires_at_ms"]
        <= offer["created_at_ms"] + 5000
    ):
        raise SetupError("DNS observation offer unavailable")
    records: list[EvidenceRecord] = []
    for record in evidence["records"]:
        if sorted(record["proofs"]) != offer["proofs"].get(record["label"]):
            raise SetupError("DNS observation proof mismatch")
        expiry = min(offer["expires_at_ms"], offer["created_at_ms"] + record["ttl_ms"])
        if expiry > current:
            records.append(
                {"label": record["label"], "proofs": record["proofs"], "expires_at_ms": expiry}
            )
    # Consume before publishing. An interrupted write grants nothing and the
    # next poll can create another offer, without replaying this one.
    path.unlink()
    publish_shared(
        shared,
        encode(
            {"binding": offer["binding"], "generation": offer["generation"], "records": records}
        ),
    )


def publish_shared(root: Path, data: bytes) -> None:
    info = root.lstat()
    if (
        not stat.S_ISDIR(info.st_mode)
        or info.st_uid != os.getuid()
        or stat.S_IMODE(info.st_mode) != 0o750
        or len(data) > 8192
    ):
        raise SetupError("DNS observation directory unavailable")
    temporary = root / (".proofs-" + secrets.token_hex(8))
    fd = os.open(temporary, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
    try:
        with os.fdopen(fd, "wb") as stream:
            stream.write(data)
            stream.flush()
            os.fchown(stream.fileno(), -1, info.st_gid)
            os.fchmod(stream.fileno(), 0o640)
            os.fsync(stream.fileno())
        os.replace(temporary, root / "current.json")
        directory = os.open(root, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        temporary.unlink(missing_ok=True)


def remaining(request: Query, root: Path = SHARED, current: int | None = None) -> int:
    """Return a duration using the same OS monotonic clock as the evidence writer."""
    current = time.monotonic_ns() // 1000000 if current is None else current
    if (
        not isinstance(request, dict)
        or set(request) != {"version", "binding", "generation", "label", "proofs"}
        or type(request["version"]) is not int
        or request["version"] != 1
        or not isinstance(request["binding"], dict)
        or set(request["binding"]) != {"placement_id", "execution_epoch", "boot_challenge"}
        or type(request["generation"]) is not int
        or not 1 <= request["generation"] <= 9223372036854775807
        or type(request["binding"]["execution_epoch"]) is not int
        or not 1 <= request["binding"]["execution_epoch"] <= 9223372036854775807
        or not isinstance(request["binding"]["boot_challenge"], str)
        or not re.fullmatch(r"[0-9a-f]{64}", request["binding"]["boot_challenge"])
    ):
        return 0
    validate(
        {
            "request_id": request["binding"]["placement_id"],
            "records": [{"label": request["label"], "proofs": request["proofs"], "ttl_ms": 1}],
        }
    )
    fd = os.open(root / "current.json", os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        if (
            not stat.S_ISREG(info.st_mode)
            or info.st_uid != os.getuid()
            or info.st_nlink != 1
            or stat.S_IMODE(info.st_mode) != 0o640
            or info.st_size > 8192
        ):
            return 0
        value: Evidence = json.loads(stream.read(8193))
    if (
        set(value) != {"binding", "generation", "records"}
        or value["binding"] != request["binding"]
        or value["generation"] != request["generation"]
        or not isinstance(value["records"], list)
        or len(value["records"]) > 16
        or not all(isinstance(item, dict) for item in value["records"])
    ):
        return 0
    found = [item for item in value["records"] if item.get("label") == request["label"]]
    if len(found) != 1:
        return 0
    record = found[0]
    if (
        set(record) != {"label", "proofs", "expires_at_ms"}
        or sorted(record["proofs"]) != sorted(request["proofs"])
        or type(record["expires_at_ms"]) is not int
        or not current < record["expires_at_ms"] <= current + 5000
    ):
        return 0
    return record["expires_at_ms"] - current


class Server:
    """@cc [owner:ghuntley,label:security;capacity] inception-proof-local-query
    The proof socket MUST accept only root or the configured Audi UID and only
    fixed proof-readiness requests. It MUST use at most four concurrent handlers,
    2048-byte frames and one 500ms deadline. Replies MUST contain only a version
    and remaining TTL; no endpoint, command, path or credential may be selected.
    Keeping expiry in Python avoids assuming BEAM and Python clock epochs match.
    """

    def __init__(self, audi_uid: int, root: Path = SHARED) -> None:
        import threading

        self.socket_module = socket
        self.threading = threading
        self.root, self.audi_uid = root, audi_uid
        info = root.lstat()
        if (
            not stat.S_ISDIR(info.st_mode)
            or info.st_uid != os.getuid()
            or stat.S_IMODE(info.st_mode) != 0o750
        ):
            raise SetupError("proof socket directory invalid")
        path = root / "verify.sock"
        if os.path.lexists(path):
            old = path.lstat()
            if not stat.S_ISSOCK(old.st_mode) or old.st_uid != os.getuid():
                raise SetupError("proof socket conflict")
            path.unlink()
        self.listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.listener.bind(str(path))
        path.chmod(0o660)
        if path.stat().st_gid != info.st_gid:
            self.listener.close()
            raise SetupError("proof socket group invalid")
        self.listener.listen(8)
        self.listener.settimeout(0.2)
        self.stopped = threading.Event()
        self.slots = threading.BoundedSemaphore(4)
        self.thread = threading.Thread(target=self.serve, daemon=True)
        self.thread.start()

    def close(self) -> None:
        self.stopped.set()
        self.listener.close()
        self.thread.join(1)
        until = time.monotonic() + 1
        for _ in range(4):
            if not self.slots.acquire(timeout=max(0, until - time.monotonic())):
                raise SetupError("proof query worker did not stop")

    def serve(self) -> None:
        while not self.stopped.is_set():
            try:
                peer, _ = self.listener.accept()
            except TimeoutError:
                continue
            except OSError:
                return
            if not self.slots.acquire(blocking=False):
                peer.close()
                continue
            self.threading.Thread(target=self.handle, args=(peer,), daemon=True).start()

    def handle(self, peer: socket.socket) -> None:
        import struct

        deadline = time.monotonic() + 0.5
        try:
            with peer:
                _, uid, _ = struct.unpack(
                    "3i", peer.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
                )
                if uid not in [0, self.audi_uid]:
                    return

                def read(count: int) -> bytes:
                    result = b""
                    while len(result) < count:
                        left = deadline - time.monotonic()
                        if left <= 0:
                            raise SetupError("proof request expired")
                        peer.settimeout(left)
                        chunk = peer.recv(count - len(result))
                        if not chunk:
                            raise SetupError("proof request incomplete")
                        result += chunk
                    return result

                (size,) = struct.unpack("!I", read(4))
                if not 1 <= size <= 2048:
                    return

                def unique(pairs: list[tuple[str, object]]) -> dict[str, object]:
                    value = {}
                    for key, item in pairs:
                        if key in value:
                            raise SetupError("duplicate proof field")
                        value[key] = item
                    return value

                request = json.loads(read(size), object_pairs_hook=unique)
                ttl = remaining(request, self.root)
                response = encode({"version": 1, "ttl_ms": ttl})
                left = deadline - time.monotonic()
                if left > 0:
                    peer.settimeout(left)
                    peer.sendall(struct.pack("!I", len(response)) + response)
        except (OSError, ValueError, TypeError, KeyError, RecursionError, SetupError):
            pass
        finally:
            self.slots.release()
