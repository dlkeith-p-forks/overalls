"""Read-only prerequisites for optional Antithesis setup profiles."""

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


def _required(name: str) -> str:
    value = os.getenv(name)
    if value is None or not value.strip():
        raise ValueError(f"missing {name}")
    return value.strip()


def repository_origin_ready(config: Config, expected_fixture_id: str) -> bool:
    """@cc [owner:ghuntley,label:verification] bootstrap-repository-authority
    Repository setup MUST require the issued registration in live SQL, an
    authenticated origin state and a successful authenticated Enrico API read.
    Missing credentials, services or observations MUST leave setup incomplete;
    asynchronous mirror publication MUST NOT be inferred from registration.
    """
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
    except (OSError, UnicodeError, ValueError):
        return False
    if fixture.fixture_id != expected_fixture_id:
        return False

    source = origin.state()
    if (
        source.state is not State.OBSERVED
        or source.value is None
        or source.value.sequence < 0
        or source.value.generation < 1
        or len(source.value.head) not in (40, 64)
        or any(character not in "0123456789abcdef" for character in source.value.head)
    ):
        return False

    sql = SqlOracle(config)
    identity = sql.select(
        "SELECT namespace, owner, name, registered_by_id FROM enrico_repositories "
        "WHERE id = %s::uuid",
        (str(fixture.repository_id),),
        maximum_rows=1,
    )
    if (
        identity.state is not State.OBSERVED
        or identity.value is None
        or len(identity.value) != 1
        or identity.value[0] != ("github", fixture.owner, fixture.name, fixture.registered_by_id)
    ):
        return False
    registration = RepositoryOracle(sql, Path("/run/overalls-enrico-state")).published(
        fixture.repository_id
    )
    if registration.state is not State.OBSERVED or registration.value is None:
        return False
    if registration.value.phase not in ("pending", "refreshing", "ready"):
        return False

    # A reserved, never-issued attempt ID exercises Enrico's authenticated
    # manager read without starting a refresh or requiring a published mirror.
    api = enrico.status(fixture.repository_id, UUID(int=0))
    return (
        api.state is State.OBSERVED
        and api.status == 200
        and api.value is not None
        and api.value.state == "missing"
    )


def access_smtp_ready(config: Config, expected_fixture_id: str) -> bool:
    """@cc [owner:ghuntley,label:verification] bootstrap-access-smtp-authority
    Access setup MUST match every issued actor to live SQL authority and
    observe the SMTP fixture through its authenticated TLS receipt endpoint.
    Missing fixtures, accounts, credentials or responses MUST leave setup incomplete.
    """
    try:
        fixture = read_access_fixture(Path(_required("ANTITHESIS_ACCESS_FIXTURE_FILE")))
        mail = MailLinks.from_environment(config.ca_file)
    except (OSError, UnicodeError, ValueError):
        return False
    if fixture.fixture_id != expected_fixture_id:
        return False

    oracle = AccessOracle(SqlOracle(config))
    for actor in (fixture.admin_a, fixture.admin_b, fixture.target):
        account = oracle.account(actor.email)
        if (
            account.state is not State.OBSERVED
            or account.value is None
            or account.value.user_id != actor.user_id
            or account.value.deleted
        ):
            return False

    receipt = mail.sequence()
    return receipt.state is State.OBSERVED and receipt.value is not None
