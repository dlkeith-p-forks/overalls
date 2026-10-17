"""One isolated measured VM and authenticated browser for a terminal command."""

import logging
import os
import time
from pathlib import Path
from uuid import UUID, uuid4

from access.browser import login_fixture, verify_fixture_login
from access.fixture import read_access_fixture
from access.mail import MailLinks
from access.oracle import AccessOracle
from admission.client import ComputeOperator, machine, provisioned
from core.config import Config
from core.interesting import choice
from core.outcome import State
from core.sql import SqlOracle
from terminal.client import TerminalClient
from terminal.guest import GuestIdentity, GuestOracle
from terminal.oracle import TerminalOracle
from terminal.scenarios import TerminalCase

LOG = logging.getLogger(__name__)


def _retire_vm(operator: ComputeOperator, sql: TerminalOracle, vm_id: UUID) -> bool:
    """@cc [owner:ghuntley,label:capacity;verification] terminal-vm-cleanup
    On command completion or post-admission setup failure, the workload MUST
    submit an authorized, idempotent delete request for its VM. Only independent
    committed archival may establish reclaimed capacity; a delete reply alone
    MUST NOT do so.
    """
    key = uuid4()
    for _ in range(2):
        try:
            submitted = operator.lifecycle(vm_id, "delete", key)
        except (OSError, ValueError):
            submitted = None
        if submitted is not None and submitted.state is State.OBSERVED:
            break
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        archived = sql.vm_archived(vm_id)
        if archived.state is State.OBSERVED and archived.value is True:
            return True
        time.sleep(0.5)
    LOG.info("terminal VM cleanup remains unverified: archived receipt unavailable")
    return False


def retire_case(case: TerminalCase) -> None:
    case.client.close()
    _retire_vm(case.operator, case.sql, case.vm_id)


def load_case() -> TerminalCase | None:
    """@cc [owner:ghuntley,label:verification] terminal-case-requires-physical-guest
    A command MUST use a unique production-admitted VM, current running
    placement, real browser login and current guest terminald witness. An
    unavailable catalog, authority, or observer MUST leave the property
    unexercised, with no fake successful VM or PTY effect.
    """
    config = Config.from_environment()
    fixture_path = Path(
        os.getenv("ANTITHESIS_ACCESS_FIXTURE_FILE", "/run/overalls-control-secrets/fixture.json")
    )
    fixture = read_access_fixture(fixture_path)
    operator_root = Path(os.environ["ANTITHESIS_CONTROL_REQUEST_DIR"])
    operator = ComputeOperator(operator_root, timeout_seconds=60)
    catalog = operator.catalog()
    if (
        catalog.state is not State.OBSERVED
        or catalog.value is None
        or not catalog.value.capacity_known
        or not catalog.value.images
    ):
        LOG.info("terminal command unexercised: no measured guest capacity")
        return None
    selected = choice(catalog.value.images)
    required_vcpu, required_memory, required_disk = selected.request_shape()
    if (
        catalog.value.available_vcpu < required_vcpu
        or catalog.value.available_memory_bytes < required_memory
        or catalog.value.available_disk_bytes < required_disk
    ):
        LOG.info("terminal command unexercised: measured capacity below guest shape")
        return None
    sql_reader = SqlOracle(config)
    sql = TerminalOracle(sql_reader)
    provision_key = uuid4()
    name = f"terminal-{uuid4().hex[:12]}"
    try:
        requested = operator.provision(provision_key, selected, name=name)
        if requested.state is not State.OBSERVED:
            requested = operator.provision(provision_key, selected, name=name)
    except (OSError, ValueError):
        requested = None
    if requested is not None and requested.value is not None and requested.value.status == "error":
        return None
    admission = provisioned(requested.value) if requested is not None and requested.value else None
    if admission is None:
        # A reply may disappear after admission commits. The immutable key
        # permits independent reconciliation and cleanup of an uncertain VM.
        for _ in range(10):
            committed = sql.vm_for_provision_key(fixture.admin_a.user_id, provision_key)
            if committed.state is State.OBSERVED and committed.value is not None:
                _retire_vm(operator, sql, committed.value)
                return None
            time.sleep(0.5)
        LOG.info("terminal provision outcome unavailable: VM cleanup identity unresolved")
        return None
    vm_id = admission.vm_id
    retained = False
    try:
        deadline = time.monotonic() + 180
        running = None
        while time.monotonic() < deadline:
            current = operator.get(vm_id)
            if current.state is State.OBSERVED and current.value is not None:
                projected = machine(current.value)
                if (
                    projected is not None
                    and projected.placement_id is not None
                    and projected.execution_epoch is not None
                    and projected.generation is not None
                    and projected.observed_state == "running"
                    and projected.desired_state == "running"
                    and not projected.archived
                ):
                    running = projected
                    break
            time.sleep(0.5)
        if (
            running is None
            or running.placement_id is None
            or running.execution_epoch is None
            or running.generation is None
        ):
            LOG.info("terminal command unexercised: VM did not reach running placement")
            return None
        guest_identity = GuestIdentity(
            running.placement_id, running.execution_epoch, running.generation
        )
        guest = GuestOracle(operator_root, guest_identity)
        guest_deadline = time.monotonic() + 60
        while time.monotonic() < guest_deadline:
            actual = guest.snapshot()
            if actual.state is State.OBSERVED and actual.value is not None:
                break
            time.sleep(0.5)
        else:
            LOG.info("terminal command unexercised: actual guest terminald witness unavailable")
            return None
        account = AccessOracle(sql_reader).account(fixture.admin_a.email)
        if account.state is not State.OBSERVED or account.value is None:
            return None
        origin = config.marshall_urls[0]
        login = login_fixture(
            config, MailLinks.from_environment(config.ca_file), fixture.admin_a, origin
        )
        if login is None:
            LOG.info("terminal command unexercised: browser login unavailable")
            return None
        if account.value.mfa_enabled and not verify_fixture_login(
            config, login, fixture.admin_a, fixture.webauthn_origin
        ):
            LOG.info("terminal command unexercised: browser MFA unavailable")
            return None
        mounted = TerminalClient.mount(login.browser, origin, vm_id, config.ca_file)
        if mounted.state is not State.OBSERVED or mounted.value is None:
            LOG.info("terminal command unexercised: authenticated TerminalLive unavailable")
            return None
        case = TerminalCase(vm_id, running.host_id, operator, mounted.value, sql, guest)
        retained = True
        return case
    finally:
        if not retained:
            _retire_vm(operator, sql, vm_id)
