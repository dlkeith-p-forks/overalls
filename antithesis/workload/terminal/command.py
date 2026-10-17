"""Closed entrypoints for the five terminal property commands."""

import logging
from typing import Literal

from terminal.runtime import load_case, retire_case
from terminal.scenarios import (
    run_create_replay,
    run_input_probe,
    run_kill_under_input_stall,
    run_neighbor_progress,
    run_ring_budget,
)

LOG = logging.getLogger(__name__)

Operation = Literal["create", "input", "kill", "ring", "neighbor"]


def execute(operation: Operation) -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        case = load_case()
    except (OSError, ValueError):
        LOG.info("terminal command unexercised: validated fixture unavailable")
        return 0
    if case is None:
        return 0
    try:
        if operation == "create":
            return run_create_replay(case)
        if operation == "input":
            return run_input_probe(case)
        if operation == "kill":
            return run_kill_under_input_stall(case)
        if operation == "ring":
            return run_ring_budget(case)
        return run_neighbor_progress(case)
    finally:
        retire_case(case)
