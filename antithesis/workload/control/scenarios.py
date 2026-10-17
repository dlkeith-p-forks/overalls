"""Control bind and credential-fence properties against real Marshall and SQL."""

import json
import logging
import os
import time
from dataclasses import dataclass
from pathlib import Path
from uuid import UUID

from antithesis.assertions import always, reachable

from control.client import ControlSession, ControlWire, WireState
from control.credential import LillyCredential, find_current_credential
from control.envelope import MAX_ID, hello, request
from control.identifiers import session_id
from control.oracle import ControlOracle
from control.rotation import RotationCoordinator
from core.config import Config, read_fixture
from core.interesting import choice
from core.outcome import State
from core.sql import SqlOracle

LOG = logging.getLogger(__name__)


@dataclass(frozen=True)
class Runtime:
    config: Config
    host_id: UUID
    machine_id: str
    credential_path: Path
    credential: LillyCredential
    oracle: ControlOracle


def _runtime() -> Runtime | None:
    config = Config.from_environment()
    fixture = read_fixture(config.fixture_manifest)
    if len(fixture.host_ids) != 1:
        raise ValueError("Control profile requires one dedicated Lilly fixture")
    host_id = fixture.host_ids[0]
    credential_path = Path(os.environ["ANTITHESIS_CONTROL_CREDENTIAL_FILE"])
    oracle = ControlOracle(SqlOracle(config))
    machine = oracle.machine_id(host_id)
    active = oracle.active_credential_id(host_id)
    if (
        machine.state is not State.OBSERVED
        or machine.value is None
        or active.state is not State.OBSERVED
        or active.value is None
    ):
        return None
    credential = find_current_credential(credential_path, host_id, active.value)
    if credential is None:
        return None
    return Runtime(config, host_id, machine.value, credential_path, credential, oracle)


def _session_body(runtime: Runtime, nonce: UUID) -> dict[str, object]:
    return {"version": 4, "session_id": str(nonce), "machine_id": runtime.machine_id}


def _negative_first_frame(
    session: ControlSession, runtime: Runtime, nonce: UUID, variant: str
) -> tuple[bool, int]:
    operation = request(choice((0, 1, MAX_ID)), "lilly.sessions", _session_body(runtime, nonce))
    if variant == "request":
        return session.first_frame(operation), 4005
    if variant == "wrong_service":
        first: str | bytes = hello("audi", {})
        close_code = 4000
    elif variant == "wrong_bind":
        first = hello("lilly", {"host_id": str(session_id())})
        close_code = 4000
    elif variant == "wrong_version":
        first = hello("lilly", {"host_id": str(runtime.host_id)}, version=2)
        close_code = 4001
    elif variant == "extra_hello_field":
        first = json.dumps(
            {
                "k": "hello",
                "v": 1,
                "service": "lilly",
                "bind": {"host_id": str(runtime.host_id)},
                "extra": 1,
            }
        )
        close_code = 4005
    elif variant == "resync":
        first = '{"k":"resync"}'
        close_code = 4005
    elif variant == "hint":
        first = json.dumps({"k": "hint", "kind": "host", "id": str(session_id())})
        close_code = 4005
    elif variant == "binary":
        first = hello("lilly", {"host_id": str(runtime.host_id)}).encode("utf-8")
        close_code = 4005
    else:
        raise ValueError("unknown Control first-frame variant")
    if not session.first_frame(first):
        return False, close_code
    # A following valid mutation request may share a network receive batch with
    # the invalid frame. Its unique session nonce is the independent SQL witness.
    session.first_frame(operation)
    return True, close_code


def run_bind_before_effects() -> int:
    """Exercise unbound application frames on the authenticated fleet socket."""
    runtime = _runtime()
    if runtime is None:
        LOG.info("Control bind property unexercised: fixture authority unavailable")
        return 0
    variants = (
        "wrong_service",
        "wrong_bind",
        "wrong_version",
        "extra_hello_field",
        "resync",
        "hint",
        "binary",
    )
    # The request-first case is guaranteed per invocation; other fixed grammar
    # cases and 5,000-ms hello-deadline neighborhoods are SDK-drawn.
    for variant in ("request", choice(variants), choice(variants)):
        nonce = session_id()
        before = runtime.oracle.session_exists(runtime.host_id, nonce)
        if before.state is not State.OBSERVED or before.value is not False:
            continue
        opening = ControlWire(
            choice(runtime.config.marshall_urls), runtime.config.ca_file, runtime.credential
        ).open()
        if opening.session is None:
            continue
        session = opening.session
        try:
            delay_ms = choice((0, 1, 4999, 5000, 5001)) if variant != "request" else 0
            if delay_ms:
                time.sleep(delay_ms / 1000)
            attempted, expected_code = _negative_first_frame(session, runtime, nonce, variant)
            if not attempted:
                continue
            event = session.receive(6)
        finally:
            session.close()
        after = runtime.oracle.session_exists(runtime.host_id, nonce)
        if after.state is State.OBSERVED and after.value is not None:
            always(
                not after.value,
                "Control domain effects require the authenticated service hello",
            )
            if (
                variant == "request"
                and event.state is WireState.CLOSED
                and event.close_code == expected_code
                and not after.value
            ):
                reachable("Control first-request refusal is observed before any domain dispatch")
    return 0


def run_credential_revalidation() -> int:
    """Rotate Lilly authority once, ending this timeline's Control workload."""
    runtime = _runtime()
    if runtime is None:
        LOG.info("Control credential property unexercised: fixture authority unavailable")
        return 0
    opening = ControlWire(
        choice(runtime.config.marshall_urls), runtime.config.ca_file, runtime.credential
    ).open()
    if opening.session is None:
        return 0
    old = opening.session
    try:
        welcome = old.bind_lilly(str(runtime.host_id))
        if welcome.state is not WireState.MESSAGE or not old.welcomed:
            return 0
        # This read-only request exercises domain reauthentication before the
        # fence when Lilly has a current execution session.
        host_session = runtime.oracle.current_host_session(runtime.host_id)
        if host_session.state is State.OBSERVED and host_session.value is not None:
            old.exchange(
                0,
                "lilly.egress_owners",
                {
                    "version": 4,
                    "session_id": str(host_session.value.session_id),
                    "epoch": host_session.value.epoch,
                    "bindings": [],
                },
            )
        coordinator = RotationCoordinator(
            Path(os.environ["ANTITHESIS_CONTROL_REQUEST_DIR"]), runtime.credential_path.parent
        )
        receipt = coordinator.rotate(session_id(), runtime.host_id)
        if receipt is None or receipt.credential.credential_id == runtime.credential.credential_id:
            return 0
        authority = runtime.oracle.credential_authority(
            runtime.host_id, runtime.credential.credential_id
        )
        if (
            authority.state is not State.OBSERVED
            or authority.value is None
            or not authority.value.old_archived
            or authority.value.active_id != receipt.credential.credential_id
        ):
            return 0
        stale_nonce = session_id()
        before = runtime.oracle.session_exists(runtime.host_id, stale_nonce)
        if before.state is not State.OBSERVED or before.value is not False:
            return 0
        stale = old.exchange(1, "lilly.sessions", _session_body(runtime, stale_nonce))
        # A current credential must remain usable. Its own distinct durable
        # session nonce distinguishes this positive effect from the stale one.
        fresh_nonce = session_id()
        fresh_opening = ControlWire(
            choice(runtime.config.marshall_urls), runtime.config.ca_file, receipt.credential
        ).open()
        if fresh_opening.session is not None:
            fresh = fresh_opening.session
            try:
                fresh_welcome = fresh.bind_lilly(str(runtime.host_id))
                if fresh_welcome.state is WireState.MESSAGE and fresh.welcomed:
                    fresh_result = fresh.exchange(
                        1, "lilly.sessions", _session_body(runtime, fresh_nonce)
                    )
                    fresh_effect = runtime.oracle.session_exists(runtime.host_id, fresh_nonce)
                    if (
                        fresh_result.acknowledged
                        and fresh_result.response is not None
                        and fresh_result.response.get("ok") is True
                        and fresh_effect.state is State.OBSERVED
                        and fresh_effect.value is True
                    ):
                        reachable(
                            "Bound control current credential completes a new session after rotation"
                        )
            finally:
                fresh.close()
        after = runtime.oracle.session_exists(runtime.host_id, stale_nonce)
        if after.state is State.OBSERVED and after.value is not None:
            # A lost response may conceal an in-flight task; only a definite
            # response or observed forbidden row gives a settled verdict.
            if stale.acknowledged or after.value:
                always(
                    not after.value,
                    "Bound control sockets revalidate current credentials before each domain effect",
                )
            if (
                stale.acknowledged
                and stale.response is not None
                and stale.response.get("ok") is False
                and stale.response.get("error") == "unauthorized"
                and not after.value
            ):
                reachable("Bound control credential rotation is refused on the next request")
        return 0
    finally:
        old.close()


def main_bind() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        return run_bind_before_effects()
    except (OSError, ValueError, KeyError):
        LOG.exception("Invalid Control bind fixture")
        return 1


def main_revalidation() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        return run_credential_revalidation()
    except (OSError, ValueError, KeyError):
        LOG.exception("Invalid Control credential fixture")
        return 1
