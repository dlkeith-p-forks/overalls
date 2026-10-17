"""Measured-ZFS admission command; requires the integrated host-vmm overlay.

This module is separate from the stub-substrate admission commands so a
profile that selects only `test/v1/admission` never declares its live-ZFS
assertions. It is selected by no profile until a measured host graph exists.
"""

import os
import time
from datetime import UTC
from pathlib import Path
from uuid import uuid4

from antithesis.assertions import always, reachable

from admission.capacity import CapacityOracle
from admission.client import provisioned
from admission.physical import PhysicalSample, read_sample
from admission.scenarios import load_runtime, new_admission
from admission.verdict import measured_capacity_verdict
from core.outcome import State


def run_measured_physical_capacity() -> int:
    """Check one admitted shape against an unchanged report and inner ZFS witness."""
    runtime = load_runtime()
    if runtime is None or len(runtime.host_ids) != 1:
        return 0
    host_id = runtime.host_ids[0]
    capacity_oracle = CapacityOracle(runtime.sql)
    pools = capacity_oracle.pool_ids(host_id)
    if pools.state is not State.OBSERVED or pools.value is None or len(pools.value) != 1:
        return 0
    pool_id = pools.value[0]
    before_result = capacity_oracle.frame(host_id, pool_id)
    if before_result.state is not State.OBSERVED or before_result.value is None:
        return 0
    before = before_result.value
    sample_path = Path(
        os.getenv("ANTITHESIS_PHYSICAL_SAMPLE_FILE", "/run/overalls-host-observation/physical.json")
    )
    frame_at_ns = int(before.observed_at.replace(tzinfo=UTC).timestamp() * 1_000_000_000)
    physical: PhysicalSample | None = None
    deadline = time.monotonic() + 4
    while time.monotonic() < deadline:
        sample = read_sample(sample_path)
        if (
            sample.state is State.OBSERVED
            and sample.value is not None
            and sample.value.sampled_at_ns >= frame_at_ns
        ):
            physical = sample.value
            break
        time.sleep(0.25)
    if physical is None:
        return 0

    key = uuid4()
    response, rows = new_admission(runtime, key, f"capacity-{key.hex[:20]}")
    if response.state is not State.OBSERVED or response.value is None:
        return 0
    if response.value.status != "ok" or rows is None:
        return 0
    receipt = provisioned(response.value)
    after = capacity_oracle.frame(host_id, pool_id)
    verdict = measured_capacity_verdict(receipt, rows, before, after, physical, runtime.image)
    if verdict is None:
        return 0
    always(
        verdict,
        "marshall placement fits fresh measured physical headroom and all outstanding holds",
    )
    if verdict:
        reachable("Marshall admitted against independently sampled live ZFS capacity")
    return 0
