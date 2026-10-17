"""Closed, bounded Control v1 JSON envelopes matching OverallsProtocol.Control.Envelope."""

import json
import re
from collections.abc import Iterable

MAX_ID = 9_007_199_254_740_991
MAX_FRAME = 1_052_672
_NAME = re.compile(r"[a-z][a-z0-9_.]{0,63}\Z")
_UUID = re.compile(r"[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\Z")


class InvalidEnvelope(ValueError):
    """Malformed or unsupported application envelope."""


def _invalid_constant(_value: str) -> object:
    raise InvalidEnvelope("non-JSON numeric constant")


def _unique_object(pairs: Iterable[tuple[str, object]]) -> dict[str, object]:
    result: dict[str, object] = {}
    for key, value in pairs:
        if key in result:
            raise InvalidEnvelope("duplicate JSON field")
        result[key] = value
    return result


def _identifier(value: object) -> bool:
    return type(value) is int and 0 <= value <= MAX_ID


def _name(value: object) -> bool:
    return isinstance(value, str) and _NAME.fullmatch(value) is not None


def decode(text: str | bytes) -> dict[str, object]:
    """@cc [owner:ghuntley,label:protocol;verification] workload-control-closed-envelope
    A received Control frame MUST be bounded UTF-8 JSON with unique keys, exactly
    the fields and value types admitted by Control v1, and no guessed fallback.
    A malformed frame MUST remain an uncertain transport observation, never an
    authenticated response or proof that no domain effect occurred.
    """
    encoded = text.encode("utf-8") if isinstance(text, str) else text
    if len(encoded) > MAX_FRAME:
        raise InvalidEnvelope("oversized Control frame")
    try:
        value: object = json.loads(
            encoded.decode("utf-8"),
            object_pairs_hook=_unique_object,
            parse_constant=_invalid_constant,
        )
    except (UnicodeDecodeError, json.JSONDecodeError) as error:
        raise InvalidEnvelope("invalid JSON frame") from error
    if not isinstance(value, dict):
        raise InvalidEnvelope("Control frame must be an object")
    message: dict[str, object] = value
    kind = message.get("k")
    if not isinstance(kind, str):
        raise InvalidEnvelope("invalid Control kind")
    keys = set(message)
    if kind == "welcome" and keys == {"k", "conn", "heartbeat_ms", "limits"}:
        limits = message["limits"]
        if (
            isinstance(message["conn"], str)
            and type(message["heartbeat_ms"]) is int
            and message["heartbeat_ms"] > 0
            and isinstance(limits, dict)
        ):
            return message
    elif kind == "res" and _identifier(message.get("id")):
        if (
            keys == {"k", "id", "ok", "body"}
            and message["ok"] is True
            and isinstance(message["body"], dict)
        ):
            return message
        if (
            keys == {"k", "id", "ok", "error"}
            and message["ok"] is False
            and _name(message["error"])
        ):
            return message
    elif kind == "hint" and keys == {"k", "kind", "id"}:
        if (
            _name(message["kind"])
            and isinstance(message["id"], str)
            and _UUID.fullmatch(message["id"])
        ):
            return message
    elif (kind == "resync" and keys == {"k"}) or (
        kind in {"ping", "pong"} and keys == {"k", "n"} and _identifier(message["n"])
    ):
        return message
    raise InvalidEnvelope("invalid Control v1 envelope")


def hello(service: str, bind: dict[str, object], *, version: int = 1) -> str:
    if not _name(service) or type(version) is not int or not isinstance(bind, dict):
        raise ValueError("invalid hello")
    return _encode({"k": "hello", "v": version, "service": service, "bind": bind})


def request(identifier: int, op: str, body: dict[str, object]) -> str:
    if not _identifier(identifier) or not _name(op) or not isinstance(body, dict):
        raise ValueError("invalid Control request")
    return _encode({"k": "req", "id": identifier, "op": op, "body": body})


def _encode(message: dict[str, object]) -> str:
    payload = json.dumps(message, separators=(",", ":"), allow_nan=False)
    if len(payload.encode("utf-8")) > MAX_FRAME:
        raise ValueError("outbound Control frame too large")
    return payload
