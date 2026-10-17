"""Closed satellite test entrypoints; no selected graph means no claimed exercise."""

import logging
import os
from typing import Literal

from satellite.editor import run_login_code_reply_loss
from satellite.runtime import delete_vm, prepare_vm
from satellite.scenarios import run_completion, run_named_integration

LOG = logging.getLogger(__name__)
Operation = Literal["completion", "integration", "editor_login"]


def execute(operation: Operation) -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    if os.getenv("ANTITHESIS_SATELLITE_READY") != "1":
        LOG.info("satellite command unexercised: selected service graph unavailable")
        return 0
    if operation == "editor_login" and not os.getenv("ANTITHESIS_EDITOR_GATEWAY_ADDRESS"):
        # Provisioning a VM would spend capacity for a history that cannot
        # reach Audi's editor callback in this graph.
        LOG.info("satellite command unexercised: Audi editor gateway is not selected")
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
        if operation == "editor_login":
            return run_login_code_reply_loss(runtime.config, runtime.vm.vm_id)
        return run_named_integration(runtime)
    finally:
        delete_vm(runtime)
