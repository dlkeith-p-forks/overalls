"""Private Audi refusal for a guest-side source Lilly never bound to a VM.

The request comes from the labelled guest stand-in in Lilly's network namespace,
not from a guest. The independent origin fixture is the effect witness: Audi's
reply alone cannot show that no provider or integration request was made.
"""

from __future__ import annotations

import logging
import os
import time
from pathlib import Path
from uuid import uuid4

from antithesis.assertions import always, reachable

from core.interesting import choice
from core.outcome import State
from satellite.origin import SatelliteOrigin
from satellite.standin import Family, GuestStandIn

LOG = logging.getLogger(__name__)


def run_unbound_source() -> int:
    """@cc [owner:ghuntley,label:security;verification] standin-unbound-no-upstream
    A stand-in request with forged VM, forwarding and credential headers MUST
    produce no origin receipt for its marker. The witness MUST read a complete
    receipt prefix after the stand-in's observed HTTP reply plus a settle window.
    Missing replies or receipt reads remain unexercised, never a pass.
    """
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        origin = SatelliteOrigin(
            os.getenv("ANTITHESIS_ORIGIN_ADMIN_URL", "http://origin:8080"),
            Path(
                os.getenv(
                    "ANTITHESIS_ORIGIN_ADMIN_TOKEN_FILE", "/run/overalls-origin-admin/admin-token"
                )
            ),
        )
        root = os.environ["ANTITHESIS_GUEST_STANDIN_ROOT"]
    except (KeyError, OSError, ValueError):
        LOG.info("unbound guest source unexercised: stand-in channel not selected")
        return 0
    standin = GuestStandIn(Path(root))
    family: Family = choice(("inference", "integration"))
    name = "llm" if family == "inference" else f"at-{uuid4().hex[:20]}"
    cursor = origin.cursor()
    marker = origin.marker()
    if (
        cursor.state is not State.OBSERVED
        or cursor.value is None
        or marker.state is not State.OBSERVED
        or marker.value is None
    ):
        LOG.info("unbound guest source unexercised: origin fixture unavailable")
        return 0
    result = standin.send(family, marker.value, name)
    if result.state is not State.OBSERVED or result.value is None:
        LOG.info("unbound guest source unexercised: stand-in result unavailable")
        return 0
    if result.value.outcome != "http" or result.value.status is None:
        LOG.info("unbound guest source unexercised: outcome=%s", result.value.outcome)
        return 0
    time.sleep(2)
    receipts = origin.receipts_after(cursor.value)
    if receipts.state is not State.OBSERVED or receipts.value is None:
        LOG.info("unbound guest source unexercised: origin receipts unavailable")
        return 0
    reachable("Guest stand-in reached private Audi over verified TLS")
    effects = receipts.value.for_marker(marker.value)
    always(
        not effects,
        "Private Audi forwards nothing for a guest source Lilly never bound",
    )
    if result.value.status == 403 and not effects:
        reachable("Private Audi refused an unbound guest-side source")
    return 0
