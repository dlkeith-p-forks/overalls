"""Read-only prerequisites for optional Antithesis setup profiles."""

import json
import logging
import os
import sqlite3
import ssl
import time
from pathlib import Path
from typing import TypeGuard
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


_RECORDER_IDENTITIES = (
    ("identity.json", "0::/fixture.slice/recorder-peer.service"),
    ("spool_identity.json", "0::/system.slice/overalls-trace-recorder.service"),
)
_RECORDER_ARCHIVE_MIN = 32 * 1024 * 1024
_RECORDER_ARCHIVE_MAX = 64 * 1024 * 1024


def _json_record(path: Path) -> dict[str, object]:
    info = path.lstat()
    if not path.is_file() or path.is_symlink() or info.st_size > 1_048_576:
        raise ValueError("recorder witness is not a bounded regular file")
    parsed: object = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(parsed, dict) or not all(isinstance(key, str) for key in parsed):
        raise ValueError("recorder witness is not an object")
    return parsed


def _positive(value: object) -> TypeGuard[int]:
    return type(value) is int and value > 0


def _recorder_paths() -> tuple[Path, Path, Path, Path]:
    paths = tuple(
        Path(_required(name))
        for name in (
            "ANTITHESIS_RECORDER_REQUESTS",
            "ANTITHESIS_RECORDER_RESULTS",
            "ANTITHESIS_RECORDER_OBSERVATION",
            "ANTITHESIS_RECORDER_LEDGER",
        )
    )
    if any(not path.is_absolute() or ".." in path.parts for path in paths):
        raise ValueError("recorder paths must be absolute without traversal")
    requests, results, observation, ledger = paths
    return requests, results, observation, ledger


def recorder_host_ready(config: Config) -> bool:
    """@cc [owner:ghuntley,label:verification] bootstrap-recorder-host-authority
    Recorder setup MUST independently read, through the workload's read-only
    observation share, a fresh all-active unit sample, both exact kernel
    service identities in their reviewed cgroups, a distinct 32-64 MiB archive
    device, a parseable recorder checkpoint whose pending admissions name only
    the current producer PID and start ticks, and a readable SQLite archive.
    The private request directory MUST be writable and its result share
    present. Missing, stale or malformed evidence MUST leave setup incomplete;
    VM health alone is not this probe.
    """
    del config
    profile = "recorder-host"
    try:
        requests, results, observation, ledger = _recorder_paths()
    except ValueError as error:
        return _incomplete(profile, f"configuration ({type(error).__name__})")
    if not requests.is_dir() or not os.access(requests, os.W_OK | os.X_OK):
        return _incomplete(profile, "request_share_unwritable")
    if not results.is_dir():
        return _incomplete(profile, "result_share_missing")
    if not ledger.parent.is_dir() or not os.access(ledger.parent, os.W_OK | os.X_OK):
        return _incomplete(profile, "ledger_volume_unwritable")
    try:
        status = _json_record(observation / "status.json")
    except (OSError, UnicodeError, ValueError) as error:
        return _incomplete(profile, f"status_unavailable ({type(error).__name__})")
    sample = status.get("sample_ns")
    if set(status) != {"sample_ns", "producer", "recorder", "spool", "archive"}:
        return _incomplete(profile, "status_malformed")
    if not _positive(sample):
        return _incomplete(profile, "status_malformed")
    if not 0 <= time.time_ns() - sample < 10_000_000_000:
        return _incomplete(profile, "status_stale")
    for unit in ("producer", "recorder", "spool", "archive"):
        if status[unit] is not True:
            return _incomplete(profile, f"unit_inactive_{unit}")
    producer: dict[str, object] = {}
    for name, cgroup in _RECORDER_IDENTITIES:
        try:
            identity = _json_record(observation / name)
        except (OSError, UnicodeError, ValueError) as error:
            return _incomplete(profile, f"identity_unavailable ({type(error).__name__})")
        if (
            set(identity) != {"pid", "uid", "start_ticks", "cgroup"}
            or identity["cgroup"] != cgroup
            or not all(_positive(identity[key]) for key in ("pid", "uid", "start_ticks"))
        ):
            return _incomplete(profile, "identity_malformed_or_foreign_cgroup")
        if name == "identity.json":
            producer = identity
    try:
        filesystem = _json_record(observation / "filesystem.json")
    except (OSError, UnicodeError, ValueError) as error:
        return _incomplete(profile, f"filesystem_unavailable ({type(error).__name__})")
    if set(filesystem) != {"archive_device", "root_device", "free_bytes", "total_bytes"} or any(
        type(value) is not int for value in filesystem.values()
    ):
        return _incomplete(profile, "filesystem_malformed")
    total = filesystem["total_bytes"]
    free = filesystem["free_bytes"]
    if (
        type(total) is not int
        or type(free) is not int
        or filesystem["archive_device"] == filesystem["root_device"]
        or not _RECORDER_ARCHIVE_MIN <= total <= _RECORDER_ARCHIVE_MAX
        or not 0 <= free <= total
    ):
        return _incomplete(profile, "archive_device_not_distinct_or_bounded")
    try:
        checkpoint = _json_record(observation / "state.json")
    except (OSError, UnicodeError, ValueError) as error:
        return _incomplete(profile, f"checkpoint_unavailable ({type(error).__name__})")
    incarnation = checkpoint.get("incarnation")
    pending = checkpoint.get("pending")
    if not isinstance(incarnation, str) or len(incarnation) != 32 or not isinstance(pending, dict):
        return _incomplete(profile, "checkpoint_malformed")
    for admission in pending.values():
        owner = admission.get("producer") if isinstance(admission, dict) else None
        if (
            not isinstance(owner, dict)
            or owner.get("pid") != producer["pid"]
            or owner.get("start_ticks") != producer["start_ticks"]
        ):
            return _incomplete(profile, "checkpoint_pending_producer_mismatch")
    archive = observation / "archive.sqlite"
    try:
        if not archive.is_file():
            return _incomplete(profile, "archive_missing")
        connection = sqlite3.connect(f"file:{archive}?mode=ro", uri=True, timeout=1)
        try:
            connection.execute("SELECT count(*) FROM batches").fetchone()
            connection.execute("SELECT count(*) FROM pending").fetchone()
        finally:
            connection.close()
    except (OSError, sqlite3.Error) as error:
        return _incomplete(profile, f"archive_unreadable ({type(error).__name__})")
    return True
