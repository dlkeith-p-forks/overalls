"""Authenticated Lilly service dispatch and version probes with SQL witnesses."""

import logging
import os
from collections.abc import Callable
from dataclasses import dataclass
from pathlib import Path
from uuid import UUID

from antithesis.assertions import always, always_or_unreachable, reachable

from control.client import ControlSession, ControlWire, RequestResult, WireState
from control.credential import LillyCredential, find_current_credential
from control.envelope import MAX_ID
from control.identifiers import session_id
from control.oracle import ControlOracle
from core.config import Config, read_fixture
from core.interesting import choice
from core.outcome import State
from core.sql import SqlOracle

LOG = logging.getLogger(__name__)


@dataclass(frozen=True)
class DispatchFixture:
    config: Config
    host_id: UUID
    machine_id: str
    credential: LillyCredential
    oracle: ControlOracle


def _fixture() -> DispatchFixture | None:
    config = Config.from_environment()
    fixture = read_fixture(config.fixture_manifest)
    if len(fixture.host_ids) != 1:
        raise ValueError("Control profile requires one dedicated Lilly fixture")
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
    path = Path(os.environ["ANTITHESIS_CONTROL_CREDENTIAL_FILE"])
    credential = find_current_credential(path, host_id, active.value)
    if credential is None:
        return None
    return DispatchFixture(config, host_id, machine.value, credential, oracle)


def _open(fixture: DispatchFixture) -> ControlSession | None:
    opening = ControlWire(
        choice(fixture.config.marshall_urls), fixture.config.ca_file, fixture.credential
    ).open()
    if opening.session is None:
        return None
    session = opening.session
    welcome = session.bind_lilly(str(fixture.host_id))
    if welcome.state is not WireState.MESSAGE or not session.welcomed:
        session.close()
        return None
    return session


def _body(fixture: DispatchFixture, nonce: UUID, version: int = 4) -> dict[str, object]:
    return {"version": version, "session_id": str(nonce), "machine_id": fixture.machine_id}


def _refused(result: RequestResult, names: frozenset[str]) -> bool:
    return (
        result.acknowledged
        and result.response is not None
        and result.response.get("ok") is False
        and result.response.get("error") in names
    )


# A syntactically valid synthetic ed25519 key: Audi's decoder accepts its shape.
_SYNTHETIC_SSH_KEY = (
    "ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIAcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcHBwcH"
)
FOREIGN_VARIANTS = ("foreign_audi", "foreign_porsche", "foreign_ziggy", "foreign_galileo")


def _foreign_request(fixture: DispatchFixture, variant: str) -> tuple[str, dict[str, object]]:
    """A document that the named foreign service's own decoder accepts.

    Sources: Audi ``Ingress.ControlRequests`` ssh-open (v1 key and label),
    Porsche ``SSHManagement.request("commands", ...)`` with a valid
    ``SSHCommand`` mutation, Ziggy v2 ``agent_next`` (empty after the version is
    removed) and Galileo ``authorize`` (a four-field private binding and an
    integration name). Each would reach its domain action if routed there.
    """
    if variant == "foreign_audi":
        return "audi.ssh_open", {
            "version": 1,
            "public_key": _SYNTHETIC_SSH_KEY,
            "label": "antithesis-probe",
        }
    if variant == "foreign_porsche":
        return "porsche.commands", {
            "version": 1,
            "session_token": "antithesis-probe-session",
            "command": {
                "version": 1,
                "command": "stop",
                "arguments": ["antithesis-probe"],
                "options": {"request-id": str(session_id())},
            },
        }
    if variant == "foreign_ziggy":
        return "ziggy.agent_next", {"version": 2}
    if variant == "foreign_galileo":
        return "galileo.authorize", {
            "binding": {
                "host_id": str(fixture.host_id),
                "vm_id": str(session_id()),
                "placement_id": str(session_id()),
                "execution_epoch": 1,
            },
            "name": "antithesis-probe",
        }
    raise ValueError("unknown foreign dispatch variant")


def _negative(
    fixture: DispatchFixture, session: ControlSession, variant: str, identifier: int
) -> None:
    """@cc [owner:ghuntley,label:verification;security] dispatch-independent-effect
    A negative attempt MUST use a fresh UUID whose absence was established by SQL
    and an observed foreign-effect snapshot taken before the request. A positive
    refusal requires a correlated response, an observed absent session row and
    unchanged foreign-effect counts; lost responses or SQL failures MUST remain
    unknown. Any observed forbidden row or changed foreign-effect count MUST fail
    safety even if the response was lost. A foreign document MUST be valid for
    its own service so that only the bound service's dispatch can refuse it.
    """
    nonce = session_id()
    before = fixture.oracle.session_exists(fixture.host_id, nonce)
    if before.state is not State.OBSERVED or before.value is not False:
        return
    effects_before = fixture.oracle.foreign_effects()
    if effects_before.state is not State.OBSERVED or effects_before.value is None:
        return
    body = _body(fixture, nonce)
    if variant in FOREIGN_VARIANTS:
        op, body = _foreign_request(fixture, variant)
        expected = frozenset({"invalid_request"})
    elif variant == "unknown_own_route":
        op = "lilly.unknown"
        expected = frozenset({"unsupported_version"})
    else:
        op = "lilly.sessions"
        expected = frozenset({"unsupported_version", "invalid_message"})
        if variant == "old_version":
            body["version"] = 3
        elif variant == "future_version":
            body["version"] = 5
        elif variant == "missing_version":
            del body["version"]
        elif variant == "extra_field":
            body["extra"] = True
        elif variant == "wrong_type":
            body["machine_id"] = 4
        elif variant == "wrong_machine":
            wrong_machine = "sha256:" + "0" * 64
            body["machine_id"] = (
                "sha256:" + "f" * 64 if fixture.machine_id == wrong_machine else wrong_machine
            )
            expected = frozenset({"machine_identity_mismatch"})
        else:
            raise ValueError("unknown Lilly dispatch variant")
    result = session.exchange(identifier, op, body)
    after = fixture.oracle.session_exists(fixture.host_id, nonce)
    effects_after = fixture.oracle.foreign_effects()
    if (
        after.state is not State.OBSERVED
        or after.value is None
        or effects_after.state is not State.OBSERVED
        or effects_after.value is None
    ):
        return
    effect_changed = effects_after.value != effects_before.value
    positively_refused = _refused(result, expected)
    unexpected_success = (
        result.acknowledged and result.response is not None and result.response.get("ok") is True
    )
    if positively_refused or unexpected_success or after.value or effect_changed:
        always(
            positively_refused and not after.value and not effect_changed,
            "Control rejects cross-service and invalid documents before domain effects",
        )
    if positively_refused and not after.value and not effect_changed:
        if variant in FOREIGN_VARIANTS:
            reachable("Control bound Lilly socket refused a valid foreign-service document")
        else:
            reachable("Control bound Lilly request reached a closed service or document refusal")


def run_dispatch() -> int:
    fixture = _fixture()
    if fixture is None:
        LOG.info("Control dispatch fixture authority unavailable")
        return 0
    session = _open(fixture)
    if session is None:
        return 0
    try:
        # Require a real durable success before claiming the negative route's
        # preconditions were reached on this service and credential.
        nonce = session_id()
        before = fixture.oracle.session_exists(fixture.host_id, nonce)
        if before.state is not State.OBSERVED or before.value is not False:
            return 0
        accepted = session.exchange(3, "lilly.sessions", _body(fixture, nonce))
        after = fixture.oracle.session_exists(fixture.host_id, nonce)
        if not (
            accepted.acknowledged
            and accepted.response is not None
            and accepted.response.get("ok") is True
            and after.state is State.OBSERVED
            and after.value is True
        ):
            return 0
        reachable("Control bound Lilly v4 session has a durable positive witness")

        # Source: each service's prefix match, Lilly's ProvisionerRequests route
        # table and foreign route decoders;
        # Execution.session/1 is closed at v4 with exactly three fields.
        variants = (
            *FOREIGN_VARIANTS,
            "unknown_own_route",
            "old_version",
            "future_version",
            "missing_version",
            "extra_field",
            "wrong_type",
            "wrong_machine",
        )
        # One valid foreign-service document is guaranteed per invocation.
        for variant in (choice(FOREIGN_VARIANTS), choice(variants), choice(variants)):
            _negative(fixture, session, variant, choice((0, 1, MAX_ID - 1, MAX_ID)))
    finally:
        session.close()
    return 0


def run_outer_version() -> int:
    """@cc [owner:ghuntley,label:verification] outer-version-scope
    This probe MUST classify only an observed 426 as a version refusal before
    upgrade. Transport failure MUST remain unknown, and this probe MUST NOT
    claim the terminal state of a BEAM service owner it cannot observe.
    """
    fixture = _fixture()
    if fixture is None:
        LOG.info("Control version fixture authority unavailable")
        return 0
    # ControlAPI.version/1 accepts exactly one header containing "1".
    for version in (2, choice((2, 255))):
        result = ControlWire(
            choice(fixture.config.marshall_urls), fixture.config.ca_file, fixture.credential
        ).open(version=version)
        if result.session is not None:
            result.session.close()
        if result.http_status is not None or result.session is not None:
            always_or_unreachable(
                result.session is None and result.http_status == 426,
                "Control wrong outer version is refused before socket upgrade",
            )
            if result.http_status == 426:
                reachable("Control wrong-version upgrade reaches permanent HTTP 426")
    return 0


def run_legacy_request() -> int:
    """@cc [owner:ghuntley,label:verification] legacy-request-scope
    A legacy request MUST be judged only after a valid v4 session succeeded on
    the same bound service and SQL confirmed the legacy nonce absent before
    dispatch. The durable command witness is Marshall's committed host session
    and epoch read before and after each legacy request; a concurrent change
    not attributable to the request MUST remain unknown. This request-side
    probe MUST NOT claim Lilly's response parser, Store, Journal or physical
    launch marker as observed.
    """
    fixture = _fixture()
    if fixture is None:
        LOG.info("Execution legacy fixture authority unavailable")
        return 0
    session = _open(fixture)
    if session is None:
        return 0
    try:
        compatible_nonce = session_id()
        compatible_before = fixture.oracle.session_exists(fixture.host_id, compatible_nonce)
        if compatible_before.state is not State.OBSERVED or compatible_before.value is not False:
            return 0
        compatible = session.exchange(3, "lilly.sessions", _body(fixture, compatible_nonce))
        compatible_after = fixture.oracle.session_exists(fixture.host_id, compatible_nonce)
        if not (
            compatible.acknowledged
            and compatible.response is not None
            and compatible.response.get("ok") is True
            and compatible_after.state is State.OBSERVED
            and compatible_after.value is True
        ):
            return 0
        reachable("Execution v4 accepted matching machine-bound session")

        # Outer Control v1 is valid. These versions belong to inner Execution.
        for index, version in enumerate((1, choice((1, 3, 5)))):
            nonce = session_id()
            before = fixture.oracle.session_exists(fixture.host_id, nonce)
            if before.state is not State.OBSERVED or before.value is not False:
                continue
            command_before = fixture.oracle.current_host_session(fixture.host_id)
            if command_before.state is not State.OBSERVED:
                continue
            result = session.exchange(index, "lilly.sessions", _body(fixture, nonce, version))
            after = fixture.oracle.session_exists(fixture.host_id, nonce)
            command_after = fixture.oracle.current_host_session(fixture.host_id)
            if (
                after.state is not State.OBSERVED
                or after.value is None
                or command_after.state is not State.OBSERVED
            ):
                continue
            # The legacy request itself would install its nonce or erase the
            # committed session. Any other change is the live Lilly runtime
            # reconnecting and leaves the unchanged-command check inconclusive.
            probe_changed = (command_after.value is None and command_before.value is not None) or (
                command_after.value is not None and command_after.value.session_id == nonce
            )
            unchanged = command_after.value == command_before.value
            positively_refused = _refused(result, frozenset({"unsupported_version"}))
            unexpected_success = (
                result.acknowledged
                and result.response is not None
                and result.response.get("ok") is True
            )
            forbidden = unexpected_success or after.value or probe_changed
            if not unchanged and not forbidden:
                LOG.info("Execution legacy durable command changed concurrently; unexercised")
                continue
            if positively_refused or forbidden:
                always_or_unreachable(
                    positively_refused and not after.value and unchanged,
                    "Execution v4 refuses legacy authority without changing durable command",
                )
            if positively_refused and not after.value and unchanged:
                reachable("Execution legacy inner session reaches authenticated decoder refusal")
    finally:
        session.close()
    return 0


def _main(run: Callable[[], int]) -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        return run()
    except (OSError, ValueError, KeyError):
        LOG.exception("Invalid Control dispatch fixture")
        return 1


def main_dispatch() -> int:
    return _main(run_dispatch)


def main_outer_version() -> int:
    return _main(run_outer_version)


def main_legacy_request() -> int:
    return _main(run_legacy_request)
