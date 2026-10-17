"""Read-only prerequisites for optional Antithesis setup profiles."""

import logging
import os
import ssl
from pathlib import Path
from uuid import UUID

from access.fixture import read_access_fixture
from access.mail import MailLinks
from access.oracle import AccessOracle
from core.config import Config
from core.outcome import State
from core.sql import SqlOracle
from repository.client import EnricoClient
from repository.fixture import GitOrigin
from repository.oracle import RepositoryOracle
from repository.runtime import read_repository_fixture

LOG = logging.getLogger(__name__)

# Distinct incomplete-prerequisite reasons already reported by this process.
_REPORTED: set[str] = set()


def _required(name: str) -> str:
    value = os.getenv(name)
    if value is None or not value.strip():
        raise ValueError(f"missing {name}")
    return value.strip()


def _incomplete(profile: str, reason: str) -> bool:
    """@cc [owner:ghuntley,label:verification] profile-readiness-diagnosable
    Each distinct unmet prerequisite MUST be reported once per process so hosted
    triage can see which gate held setup incomplete. The reason MUST name only
    fixed condition tokens, observation states, HTTP statuses, nonsecret enum
    values and error classes: never credentials, tokens, paths or payloads.
    """
    if reason not in _REPORTED:
        _REPORTED.add(reason)
        LOG.warning("%s setup prerequisite incomplete: %s", profile, reason)
    return False


def repository_origin_ready(config: Config, expected_fixture_id: str) -> bool:
    """@cc [owner:ghuntley,label:verification] bootstrap-repository-authority
    Repository setup MUST require the issued registration in live SQL, an
    authenticated origin state and a successful authenticated Enrico API read.
    Missing credentials, services or observations MUST leave setup incomplete;
    asynchronous mirror publication MUST NOT be inferred from registration.
    """
    profile = "repository-origin"
    try:
        fixture = read_repository_fixture(Path(_required("ANTITHESIS_REPOSITORY_FIXTURE_FILE")))
        ssl.create_default_context(
            cafile=os.getenv("ANTITHESIS_ORIGIN_CA_FILE", "/run/overalls-origin-ca/ca.pem")
        )
        origin = GitOrigin(
            _required("ANTITHESIS_ORIGIN_ADMIN_URL"),
            Path(_required("ANTITHESIS_ORIGIN_ADMIN_TOKEN_FILE")),
        )
        enrico = EnricoClient(
            _required("ANTITHESIS_ENRICO_URL"),
            Path(_required("ANTITHESIS_ENRICO_CA_FILE")),
            Path(_required("ANTITHESIS_ENRICO_TOKEN_FILE")),
        )
    except (OSError, UnicodeError, ValueError) as error:
        return _incomplete(profile, f"configuration_or_credentials ({type(error).__name__})")
    if fixture.fixture_id != expected_fixture_id:
        return _incomplete(profile, "fixture_id_mismatch")

    source = origin.state()
    if source.state is not State.OBSERVED or source.value is None:
        return _incomplete(profile, f"origin_state_{source.state.value}")
    if (
        source.value.sequence < 0
        or source.value.generation < 1
        or len(source.value.head) not in (40, 64)
        or any(character not in "0123456789abcdef" for character in source.value.head)
    ):
        return _incomplete(profile, "origin_state_invalid")

    sql = SqlOracle(config)
    identity = sql.select(
        "SELECT namespace, owner, name, registered_by_id FROM enrico_repositories "
        "WHERE id = %s::uuid",
        (str(fixture.repository_id),),
        maximum_rows=1,
    )
    if identity.state is not State.OBSERVED or identity.value is None:
        return _incomplete(profile, f"sql_registration_{identity.state.value}")
    if len(identity.value) != 1:
        return _incomplete(profile, "sql_registration_missing")
    if identity.value[0] != ("github", fixture.owner, fixture.name, fixture.registered_by_id):
        return _incomplete(profile, "sql_registration_identity_mismatch")
    registration = RepositoryOracle(sql, Path("/run/overalls-enrico-state")).published(
        fixture.repository_id
    )
    if registration.state is not State.OBSERVED or registration.value is None:
        return _incomplete(profile, f"sql_publication_{registration.state.value}")
    if registration.value.phase not in ("pending", "refreshing", "ready"):
        return _incomplete(profile, f"sql_publication_phase_{registration.value.phase}")

    # A reserved, never-issued attempt ID exercises Enrico's authenticated
    # manager read without starting a refresh or requiring a published mirror.
    api = enrico.status(fixture.repository_id, UUID(int=0))
    if api.state is not State.OBSERVED or api.status != 200 or api.value is None:
        return _incomplete(profile, f"enrico_status_{api.state.value}_http_{api.status}")
    if api.value.state != "missing":
        return _incomplete(profile, f"enrico_status_attempt_{api.value.state}")
    return True


def access_smtp_ready(config: Config, expected_fixture_id: str) -> bool:
    """@cc [owner:ghuntley,label:verification] bootstrap-access-smtp-authority
    Access setup MUST match every issued actor to live SQL authority and
    observe the SMTP fixture through its authenticated TLS receipt endpoint.
    Missing fixtures, accounts, credentials or responses MUST leave setup incomplete.
    """
    profile = "access-smtp"
    try:
        fixture = read_access_fixture(Path(_required("ANTITHESIS_ACCESS_FIXTURE_FILE")))
        mail = MailLinks.from_environment(config.ca_file)
    except (OSError, UnicodeError, ValueError) as error:
        return _incomplete(profile, f"configuration_or_credentials ({type(error).__name__})")
    if fixture.fixture_id != expected_fixture_id:
        return _incomplete(profile, "fixture_id_mismatch")

    oracle = AccessOracle(SqlOracle(config))
    for role, actor in (
        ("admin_a", fixture.admin_a),
        ("admin_b", fixture.admin_b),
        ("target", fixture.target),
    ):
        account = oracle.account(actor.email)
        if account.state is not State.OBSERVED or account.value is None:
            return _incomplete(profile, f"sql_account_{role}_{account.state.value}")
        if account.value.user_id != actor.user_id or account.value.deleted:
            return _incomplete(profile, f"sql_account_{role}_identity_mismatch")

    receipt = mail.sequence()
    if receipt.state is not State.OBSERVED or receipt.value is None:
        return _incomplete(profile, f"smtp_receipt_{receipt.state.value}")
    return True
