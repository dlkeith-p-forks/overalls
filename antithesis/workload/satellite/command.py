"""Closed satellite test entrypoints; no selected graph means no claimed exercise."""

import logging
import os
from typing import Literal

from satellite.runtime import delete_vm, prepare_vm
from satellite.scenarios import run_completion, run_named_integration

LOG = logging.getLogger(__name__)
Operation = Literal["completion", "integration"]


def execute(operation: Operation) -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    if os.getenv("ANTITHESIS_SATELLITE_READY") != "1":
        LOG.info("satellite command unexercised: selected service graph unavailable")
        return 0
    try:
        runtime = prepare_vm()
    except (OSError, ValueError):
        LOG.info("satellite command unexercised: prerequisite unavailable")
        return 0
    if runtime is None:
        LOG.info("satellite command unexercised: no current real guest placement")
        return 0
    try:
        if operation == "completion":
            return run_completion(runtime)
        return run_named_integration(runtime)
    finally:
        delete_vm(runtime)
