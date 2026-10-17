"""Reply correlation and retirement for the real shared BEAM Control client."""

import logging

from antithesis.assertions import always, reachable

from control.peer import run_peer
from core.interesting import choice
from core.outcome import State

LOG = logging.getLogger(__name__)


def run_pending() -> int:
    """@cc [owner:ghuntley,label:verification] pending-requires-caller-wire-ledger
    A settled caller MUST match the peer-observed wire ID and nonce. A timed
    out or lost caller MUST remain uncertain about any remote domain effect;
    only a complete ledger may produce a retirement verdict.
    """
    # 0/257 exercise fallback eight; 8/64/256 exercise negotiated windows.
    # A one-slot welcome cannot host the two-call reorder scenario.
    limit = choice((0, 8, 64, 256, 257))
    timeout_ms = choice((50, 500, 5_000))
    result = run_peer("pending", limit, timeout_ms)
    if result.state is not State.OBSERVED or result.value is None:
        LOG.info("Control pending peer unavailable")
        return 0
    fields = result.value
    flags = (
        fields.flag("distinct_ids"),
        fields.flag("reordered_matching"),
        fields.flag("timeout_retired"),
        fields.flag("late_ignored"),
        fields.flag("loss_unproven"),
        fields.flag("no_replay"),
        fields.flag("sentinel_matching"),
    )
    if any(flag is None for flag in flags):
        LOG.info("Control pending peer result incomplete")
        return 0
    valid = all(flags)
    always(
        valid,
        "Control responses settle only their live pending request",
        {"advertised_limit": limit, "request_timeout_ms": timeout_ms},
    )
    if valid:
        reachable("Control late retired response is ignored while fresh work completes")
    return 0
