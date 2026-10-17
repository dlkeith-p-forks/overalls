"""Serialize repository campaigns that mutate the one synthetic Git origin."""

import fcntl
import logging
import os
from collections.abc import Callable
from pathlib import Path

LOG = logging.getLogger(__name__)


def run_exclusive(action: Callable[[], int]) -> int:
    """@cc [owner:ghuntley,label:verification] repository-fixture-exclusive-campaign
    A repository command MUST hold one workload-owned campaign lock while it
    changes the fixture's Git ref or fault mode. Contention MUST leave the
    command unexercised without changing shared fixture state.
    """
    root = Path(os.getenv("ANTITHESIS_REPOSITORY_CAMPAIGN_DIR", "/tmp"))
    descriptor = os.open(root / "repository-campaign.lock", os.O_RDWR | os.O_CREAT, 0o600)
    try:
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            LOG.info("Enrico repository campaign unexercised: another campaign owns the fixture")
            return 0
        return action()
    finally:
        os.close(descriptor)
