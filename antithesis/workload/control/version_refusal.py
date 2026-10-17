"""Control 4001 version refusal against the real shared BEAM Control client."""

import logging

from antithesis.assertions import always, reachable

from control.peer import PeerResult, run_peer
from core.interesting import choice
from core.outcome import State

LOG = logging.getLogger(__name__)

# Longer than the client's 4_000 ms reconnect ceiling; see runner.exs.
_QUIET_MS = 5_000


def _verdict(fields: PeerResult) -> bool | None:
    """Return the terminal-refusal verdict, or None when the ledger is incomplete."""
    flags = (
        fields.flag("close_class"),
        fields.flag("pending_unproven"),
        fields.flag("status_retained"),
        fields.flag("post_refusal_disconnected"),
        fields.flag("client_alive"),
    )
    handshakes = fields.count("handshakes_after_refusal")
    quiet = fields.count("quiet_ms")
    if any(flag is None for flag in flags) or handshakes is None or quiet != _QUIET_MS:
        return None
    return all(flags) and handshakes == 0


def run_version_refusal() -> int:
    """@cc [owner:ghuntley,label:verification] version-refusal-peer-ledger
    The terminal version verdict MUST come from the real shared BEAM client and
    the loopback peer's accept ledger after a welcomed 4001 close with one held
    request. Peer failure or an incomplete record MUST leave the property
    unexercised. The bounded quiet window MUST NOT be described as proof of no
    later retry, and this probe MUST NOT claim Marshall's 426/4001 emission or a
    service adapter's owner stop, which it does not observe.
    """
    # Advertised windows include the invalid 0/257 fallback; the hold delay
    # varies when the refusal lands relative to the client's heartbeat.
    limit = choice((0, 1, 8, 64, 255, 256, 257))
    hold_ms = choice((50, 500, 5_000))
    result = run_peer("version_refusal", limit, hold_ms)
    if result.state is not State.OBSERVED or result.value is None:
        LOG.info("Control version refusal peer unavailable")
        return 0
    verdict = _verdict(result.value)
    if verdict is None:
        LOG.info("Control version refusal peer result incomplete")
        return 0
    always(
        verdict,
        "Control transport version refusal stops its owner without losing its class",
        {"advertised_limit": limit, "hold_ms": hold_ms, "quiet_ms": _QUIET_MS},
    )
    if verdict:
        reachable("Control 4001 refusal retired a held call and stayed stopped past backoff")
    return 0


def main_version_refusal() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        return run_version_refusal()
    except (OSError, ValueError):
        LOG.exception("Invalid Control version refusal draw")
        return 1
