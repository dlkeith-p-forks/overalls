"""Delivery histories against real Control sockets and independent SQL receipts."""

import logging
import os
from dataclasses import dataclass
from pathlib import Path
from uuid import UUID

from antithesis.assertions import always, reachable

from control.client import ControlWire, RequestResult, WireState
from control.credential import LillyCredential, find_current_credential
from control.envelope import request
from control.identifiers import session_id
from control.oracle import ControlOracle
from control.peer import PeerResult, run_peer
from core.config import Config, read_fixture
from core.interesting import choice
from core.outcome import State
from core.sql import SqlOracle

LOG = logging.getLogger(__name__)


@dataclass(frozen=True)
class DeliveryRuntime:
    config: Config
    host_id: UUID
    machine_id: str
    credential: LillyCredential
    oracle: ControlOracle


@dataclass(frozen=True)
class EffectReceipt:
    """One explicit call and one independently queried durable effect identity."""

    wire_id: int
    operation_id: UUID
    attempted: bool
    acknowledged: bool
    committed: bool | None


@dataclass(frozen=True)
class PeerDelivery:
    """Complete socket observations from the real BEAM Control client peer."""

    first_frame_count: int
    old_frame_count_after_reconnect: int
    recovered_handshakes: int
    sentinel_count: int
    uncertain: bool
    sentinel_ack: bool
    distinct_ids: bool


def _peer_delivery(result: PeerResult) -> PeerDelivery | None:
    """Require the complete typed result from the shared runner parser."""
    if set(result.fields) != {
        "first_frame_count",
        "old_frame_count_after_reconnect",
        "recovered_handshakes",
        "sentinel_count",
        "uncertain",
        "sentinel_ack",
        "distinct_ids",
    }:
        return None
    first = result.count("first_frame_count")
    old = result.count("old_frame_count_after_reconnect")
    handshakes = result.count("recovered_handshakes")
    sentinel = result.count("sentinel_count")
    uncertain = result.flag("uncertain")
    sentinel_ack = result.flag("sentinel_ack")
    distinct_ids = result.flag("distinct_ids")
    if any(
        value is None
        for value in (first, old, handshakes, sentinel, uncertain, sentinel_ack, distinct_ids)
    ):
        return None
    assert first is not None and old is not None and handshakes is not None and sentinel is not None
    assert uncertain is not None and sentinel_ack is not None and distinct_ids is not None
    return PeerDelivery(
        first_frame_count=first,
        old_frame_count_after_reconnect=old,
        recovered_handshakes=handshakes,
        sentinel_count=sentinel,
        uncertain=uncertain,
        sentinel_ack=sentinel_ack,
        distinct_ids=distinct_ids,
    )


def delivery_verdict(peer: PeerDelivery) -> bool | None:
    """@cc [owner:ghuntley,label:verification] delivery-peer-proof-boundary
    The primary verdict MUST use peer-observed frame counts from the real BEAM
    client and an acknowledged fresh sentinel after two recovered handshakes.
    An unavailable or incomplete ledger MUST NOT become a passing assertion.
    """
    if peer.first_frame_count > 1 or peer.old_frame_count_after_reconnect > 0:
        return False
    if (
        peer.first_frame_count == 1
        and peer.old_frame_count_after_reconnect == 0
        and peer.recovered_handshakes >= 2
        and peer.sentinel_count == 1
        and peer.uncertain
        and peer.sentinel_ack
        and peer.distinct_ids
    ):
        return True
    return None


def run_peer_delivery() -> bool | None:
    """Exercise the actual Control client state machine through its wire peer."""
    observation = run_peer("delivery", 8, 500)
    if observation.state is not State.OBSERVED or observation.value is None:
        return None
    peer = _peer_delivery(observation.value)
    if peer is None:
        return None
    verdict = delivery_verdict(peer)
    if verdict is not None:
        always(verdict, "Control transport never redelivers an uncertain application call")
    return verdict


def _runtime() -> DeliveryRuntime | None:
    config = Config.from_environment()
    fixture = read_fixture(config.fixture_manifest)
    if len(fixture.host_ids) != 1:
        raise ValueError("Control delivery requires one dedicated Lilly fixture")
    host_id = fixture.host_ids[0]
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
    credential_path = Path(os.environ["ANTITHESIS_CONTROL_CREDENTIAL_FILE"])
    credential = find_current_credential(credential_path, host_id, active.value)
    if credential is None:
        return None
    return DeliveryRuntime(config, host_id, machine.value, credential, oracle)


def _new_socket(runtime: DeliveryRuntime) -> ControlWire:
    return ControlWire(
        choice(runtime.config.marshall_urls), runtime.config.ca_file, runtime.credential
    )


def _session_body(runtime: DeliveryRuntime, operation_id: UUID) -> dict[str, object]:
    return {
        "version": 4,
        "session_id": str(operation_id),
        "machine_id": runtime.machine_id,
    }


def _effect_receipt(
    runtime: DeliveryRuntime,
    wire_id: int,
    operation_id: UUID,
    attempted: bool,
    acknowledged: bool,
) -> EffectReceipt:
    """@cc [owner:ghuntley,label:verification] delivery-effect-unknown
    Only a successful SQL read of the exact unique operation ID may establish
    commit or absence at the sampled instant. A lost reply or failed SQL read
    MUST remain unknown; it cannot establish rollback or a refusal.
    """
    effect = runtime.oracle.session_exists(runtime.host_id, operation_id)
    committed = effect.value if effect.state is State.OBSERVED else None
    return EffectReceipt(wire_id, operation_id, attempted, acknowledged, committed)


def _send_uncertain_session(runtime: DeliveryRuntime, operation_id: UUID) -> EffectReceipt:
    """Send one real authenticated frame and close before receiving its reply."""
    opening = _new_socket(runtime).open()
    if opening.session is None:
        return EffectReceipt(1, operation_id, False, False, None)
    session = opening.session
    try:
        welcome = session.bind_lilly(str(runtime.host_id))
        if welcome.state is not WireState.MESSAGE or not session.welcomed:
            return EffectReceipt(1, operation_id, False, False, None)
        session.send_raw_frame(request(1, "lilly.sessions", _session_body(runtime, operation_id)))
    finally:
        session.close()
    # send_raw_frame reports false for an uncertain send, not proof that the
    # frame missed Marshall. Query the durable effect either way.
    return _effect_receipt(runtime, 1, operation_id, True, False)


def _send_sentinel_session(runtime: DeliveryRuntime, operation_id: UUID) -> EffectReceipt:
    opening = _new_socket(runtime).open()
    if opening.session is None:
        return EffectReceipt(2, operation_id, False, False, None)
    session = opening.session
    try:
        welcome = session.bind_lilly(str(runtime.host_id))
        if welcome.state is not WireState.MESSAGE or not session.welcomed:
            return EffectReceipt(2, operation_id, False, False, None)
        result: RequestResult = session.exchange(
            2, "lilly.sessions", _session_body(runtime, operation_id)
        )
    finally:
        session.close()
    return _effect_receipt(runtime, 2, operation_id, result.attempted, result.acknowledged)


def run_ambiguous_commit() -> tuple[EffectReceipt, EffectReceipt] | None:
    """Keep transport invocation and domain operation identities separate."""
    runtime = _runtime()
    if runtime is None:
        LOG.info("Control delivery history unexercised: fixture authority unavailable")
        return None
    uncertain_id = session_id()
    sentinel_id = session_id()
    if uncertain_id == sentinel_id:
        return None
    before_uncertain = runtime.oracle.session_exists(runtime.host_id, uncertain_id)
    before_sentinel = runtime.oracle.session_exists(runtime.host_id, sentinel_id)
    if (
        before_uncertain.state is not State.OBSERVED
        or before_uncertain.value is not False
        or before_sentinel.state is not State.OBSERVED
        or before_sentinel.value is not False
    ):
        return None
    uncertain = _send_uncertain_session(runtime, uncertain_id)
    sentinel = _send_sentinel_session(runtime, sentinel_id)
    if sentinel.acknowledged and sentinel.committed is True:
        reachable("Control delivery sentinel has a distinct committed session receipt")
    if uncertain.attempted and uncertain.committed is True and not uncertain.acknowledged:
        reachable("Control lost reply may conceal a committed domain effect")
    return uncertain, sentinel


def main_redelivery() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        peer = run_peer_delivery()
        if peer is None:
            LOG.info(
                "Control redelivery peer ledger unexercised: complete wire evidence unavailable"
            )
    except (OSError, ValueError, KeyError):
        LOG.exception("Invalid Control delivery fixture")
        return 1
    return 0


def main_ambiguous_commit() -> int:
    """Run the unique SQL-effect history only on a terminal fixture timeline."""
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        run_ambiguous_commit()
    except (OSError, ValueError, KeyError):
        LOG.exception("Invalid Control delivery fixture")
        return 1
    return 0
