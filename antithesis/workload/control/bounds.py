"""Negotiated pending-window and wire-frame capacity property."""

import logging

from antithesis.assertions import always, reachable

from control.peer import run_peer
from core.interesting import choice
from core.outcome import State

LOG = logging.getLogger(__name__)


def run_bounds() -> int:
    """@cc [owner:ghuntley,label:verification] bounds-require-peer-inventory
    A capacity assertion MUST use the real shared BEAM client and the peer's
    complete frame inventory. A failed peer, missing field or transport loss
    MUST leave this property unexercised, never count as a busy refusal.
    """
    # Valid windows and the invalid 0/257 fallback exercise the source's
    # 1..256 negotiated boundary; the exact window plus one is sent each run.
    limit = choice((0, 1, 8, 64, 255, 256, 257))
    result = run_peer("capacity", limit, 500)
    if result.state is not State.OBSERVED or result.value is None:
        LOG.info("Control capacity peer unavailable")
        return 0
    fields = result.value
    expected = limit if 1 <= limit <= 256 else 8
    flags = (
        fields.flag("inventory_complete"),
        fields.flag("wire_ids_unique"),
        fields.flag("busy"),
        fields.flag("busy_no_frame"),
        fields.flag("matching"),
        fields.flag("no_replay"),
        fields.flag("fresh"),
    )
    observed = fields.count("observed")
    negotiated = fields.count("limit")
    if any(flag is None for flag in flags) or observed is None or negotiated is None:
        LOG.info("Control capacity peer result incomplete")
        return 0
    valid = negotiated == expected and observed == expected and all(flags)
    always(
        valid,
        "control client pending requests fit negotiated window and busy calls send no frame",
        {"advertised_limit": limit, "expected_limit": expected, "observed_frames": observed},
    )
    if valid:
        reachable("Control negotiated window saturates then admits fresh work")
    return 0
