"""One dedicated real VM and the independent satellite fixture observers."""

import os
import time
from dataclasses import dataclass
from pathlib import Path
from uuid import uuid4

from access.fixture import read_access_fixture
from admission.client import ComputeOperator, Provisioned, machine, provisioned
from core.config import Config
from core.outcome import State
from core.sql import SqlOracle
from satellite.authority import IntegrationAuthority
from satellite.operator import IntegrationOperator
from satellite.oracle import InferenceOracle
from satellite.origin import SatelliteOrigin


@dataclass(frozen=True)
class Runtime:
    config: Config
    vm: Provisioned
    compute: ComputeOperator
    integrations: IntegrationOperator
    authority: IntegrationAuthority
    inference: InferenceOracle
    origin: SatelliteOrigin


def prepare_vm() -> Runtime | None:
    """@cc [owner:ghuntley,label:verification] satellite-real-placement
    A workload VM MUST be provisioned by the authenticated closed Compute
    action and observed running under its current placement before guest
    requests begin. A fixture manifest or ready marker alone is insufficient.
    """
    config = Config.from_environment()
    actor = read_access_fixture(Path("/run/overalls-control-secrets/fixture.json")).admin_a
    root = Path(os.getenv("ANTITHESIS_CONTROL_OPERATOR_ROOT", "/run/overalls-control-requests"))
    compute = ComputeOperator(root)
    catalog = compute.catalog()
    if (
        catalog.state is not State.OBSERVED
        or catalog.value is None
        or not catalog.value.capacity_known
    ):
        return None
    selected = next(
        (
            image
            for image in catalog.value.images
            if catalog.value.available_vcpu >= image.request_shape()[0]
            and catalog.value.available_memory_bytes >= image.request_shape()[1] + 67_108_864
            and catalog.value.available_disk_bytes >= image.request_shape()[2] + 1_073_741_824
        ),
        None,
    )
    if selected is None:
        return None
    key = uuid4()
    created = compute.provision(key, selected, name=f"satellite-{key.hex[:16]}")
    if created.state is not State.OBSERVED or created.value is None:
        return None
    vm = provisioned(created.value)
    if vm is None or vm.owner_id != actor.user_id:
        return None
    deadline = time.monotonic() + 180
    started = False
    while time.monotonic() < deadline:
        current = compute.get(vm.vm_id)
        if (
            current.state is State.OBSERVED
            and current.value is not None
            and current.value.status == "ok"
        ):
            value = machine(current.value)
            if value is not None:
                if (
                    value.vm_id == vm.vm_id
                    and value.owner_id == vm.owner_id
                    and value.placement_id == vm.placement_id
                    and value.host_id == vm.host_id
                    and value.execution_epoch == vm.execution_epoch
                    and value.generation == vm.generation
                    and value.desired_state == "running"
                    and value.observed_state == "running"
                    and not value.archived
                ):
                    return Runtime(
                        config,
                        vm,
                        compute,
                        IntegrationOperator(root),
                        IntegrationAuthority(SqlOracle(config)),
                        InferenceOracle(SqlOracle(config)),
                        SatelliteOrigin(
                            os.getenv("ANTITHESIS_ORIGIN_ADMIN_URL", "http://origin:8080"),
                            Path(
                                os.getenv(
                                    "ANTITHESIS_ORIGIN_ADMIN_TOKEN_FILE",
                                    "/run/overalls-origin-admin/admin-token",
                                )
                            ),
                        ),
                    )
                if value.desired_state == "stopped" and not started:
                    command = compute.lifecycle(vm.vm_id, "start", uuid4())
                    if (
                        command.state is not State.OBSERVED
                        or command.value is None
                        or command.value.status != "ok"
                    ):
                        return None
                    started = True
        time.sleep(1)
    return None


def delete_vm(runtime: Runtime) -> None:
    # Deletion uses ordinary Compute authority. A missing reply is uncertain;
    # the workload does not claim resource retirement from this best-effort call.
    runtime.compute.lifecycle(runtime.vm.vm_id, "delete", uuid4())
