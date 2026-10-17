"""Read-only prerequisites for optional Antithesis setup profiles."""

import json
import logging
import os
import re
import secrets
import sqlite3
import ssl
import stat
import subprocess
import tempfile
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
from guest_lifecycle.readiness import substrate_gap
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


# Static ValueError messages raised by reviewed fixture/configuration parsers.
# Only these, never arbitrary exception text, may be echoed into a reason.
_REVIEWED_CONFIGURATION_ERRORS = frozenset(
    {
        "invalid access fixture",
        "invalid access fixture actor",
        "invalid synthetic actor email",
        "invalid fixture authenticator",
        "invalid fixture identity",
        "invalid WebAuthn origin",
        "invalid WebAuthn RP binding",
        "duplicate access fixture actor",
        "unreviewed SMTP fixture endpoint",
    }
)
_MISSING_VARIABLE = re.compile(r"missing [A-Z][A-Z0-9_]{0,63}")


def _configuration_reason(error: Exception) -> str:
    """Name the failed configuration check without echoing untrusted text."""
    message = str(error)
    if isinstance(error, ValueError) and (
        message in _REVIEWED_CONFIGURATION_ERRORS or _MISSING_VARIABLE.fullmatch(message)
    ):
        return f"configuration_or_credentials ({type(error).__name__}: {message})"
    return f"configuration_or_credentials ({type(error).__name__})"


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
        return _incomplete(profile, _configuration_reason(error))
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
        return _incomplete(profile, _configuration_reason(error))
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


_STUB_POOL_IDENTITY = ("10001", "10002", "overalls/antithesis")


def admission_stub_ready(config: Config, host_ids: tuple[UUID, ...]) -> bool:
    """@cc [owner:ghuntley,label:verification;capacity] bootstrap-admission-stub-authority
    Admission-stub setup MUST observe, through the SELECT-only oracle, that
    Marshall committed for the single fixture host an administrative enable in
    normal maintenance mode, a fresh execution-ready report with measured v1 compute headroom, a fresh pool observation with
    positive free bytes under the stub's configured pool identity, and an
    enabled catalog image that the host advertises. These rows show only that
    Marshall can make a real admission decision on stub storage; they are not
    ZFS, KVM or isolation evidence. Missing or stale rows MUST leave setup
    incomplete.
    """
    profile = "admission-stub"
    if len(host_ids) != 1:
        return _incomplete(profile, "fixture_host_count")
    observed = SqlOracle(config).select(
        "SELECT h.enabled AND h.maintenance_mode = 'normal', "
        "h.inventory -> 'execution_ready' = 'true'::jsonb, "
        "h.capacity ->> 'version' = '1', "
        "h.reported_at >= now() - interval '5 seconds', "
        "(SELECT count(*) FROM compute_storage_pools p WHERE p.host_id = h.id "
        "AND p.reported_at >= now() - interval '5 seconds' AND p.free_bytes > 0 "
        "AND p.zpool_guid = %s AND p.dataset_guid = %s AND p.dataset = %s), "
        "(SELECT count(*) FROM compute_images i WHERE i.enabled "
        "AND COALESCE(h.inventory -> 'images', '[]'::jsonb) @> jsonb_build_array(i.id)) "
        "FROM compute_hosts h WHERE h.id = %s::uuid",
        (*_STUB_POOL_IDENTITY, str(host_ids[0])),
        maximum_rows=1,
    )
    if observed.state is not State.OBSERVED or observed.value is None:
        return _incomplete(profile, f"sql_host_{observed.state.value}")
    if len(observed.value) != 1:
        return _incomplete(profile, "sql_host_missing")
    enabled, ready, capacity, fresh, pools, images = observed.value[0]
    for name, value in (
        ("enabled", enabled),
        ("execution_ready", ready),
        ("capacity", capacity),
        ("fresh", fresh),
    ):
        if value is not True:
            return _incomplete(profile, f"host_{name}_not_observed")
    if type(pools) is not int or pools < 1:
        return _incomplete(profile, "stub_pool_observation_missing")
    if type(images) is not int or images < 1:
        return _incomplete(profile, "advertised_enabled_image_missing")
    return True


BACKUP_MODULES = Path("/opt/overalls/backup-modules/runtime.py")
RESTIC = Path("/opt/overalls/restic/bin/restic")


def _private_directory(path: Path) -> bool:
    if not path.is_absolute() or ".." in path.parts or path.is_symlink():
        return False
    observed = path.lstat()
    return (
        stat.S_ISDIR(observed.st_mode)
        and observed.st_uid in (0, os.geteuid())
        and not observed.st_mode & 0o022
    )


def _restic(
    arguments: list[str], environment: dict[str, str]
) -> subprocess.CompletedProcess[bytes]:
    return subprocess.run(
        [str(RESTIC), *arguments],
        env=environment,
        stdin=subprocess.DEVNULL,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        timeout=60,
        check=False,
    )


def backup_restic_ready() -> bool:
    """@cc [owner:ghuntley,label:verification] bootstrap-backup-restic-fixture
    Backup setup MUST find the production backup operator and pinned Restic in
    the image, a private fixture volume, and a real disposable encrypted Restic
    repository that initializes and enumerates empty there. The probe repository
    MUST be removed afterward. A missing tool, unsafe root or failed Restic call
    MUST leave setup incomplete; readiness never implies a backup was taken.
    """
    profile = "backup-restic"
    try:
        root = Path(_required("ANTITHESIS_BACKUP_ROOT"))
    except ValueError as error:
        return _incomplete(profile, f"configuration ({type(error).__name__})")
    if not BACKUP_MODULES.is_file() or not RESTIC.is_file():
        return _incomplete(profile, "backup_operator_or_restic_absent")
    try:
        if not _private_directory(root):
            return _incomplete(profile, "fixture_root_unsafe")
        with tempfile.TemporaryDirectory(
            prefix="overalls-antithesis-backup-probe-", dir=root
        ) as temporary:
            probe = Path(temporary)
            password = probe / "password"
            password.write_text(secrets.token_hex(32) + "\n", encoding="ascii")
            password.chmod(0o600)
            environment = {
                "PATH": "/usr/bin:/bin",
                "HOME": str(probe),
                "RESTIC_REPOSITORY": str(probe / "repository"),
                "RESTIC_PASSWORD_FILE": str(password),
                "RESTIC_CACHE_DIR": str(probe / "cache"),
                "LC_ALL": "C",
                "TZ": "UTC",
            }
            if _restic(["init"], environment).returncode != 0:
                return _incomplete(profile, "restic_init_failed")
            listed = _restic(["snapshots", "--json"], environment)
            if listed.returncode != 0:
                return _incomplete(profile, "restic_enumeration_failed")
            inventory: object = json.loads(listed.stdout)
            if inventory != []:
                return _incomplete(profile, "restic_probe_not_empty")
    except (OSError, subprocess.SubprocessError, ValueError) as error:
        return _incomplete(profile, f"restic_probe ({type(error).__name__})")
    return True


def _channel_receipt(path: Path) -> str | None:
    """Return the stand-in's fixed readiness verdict, or None when absent."""
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 4096:
        return None
    value: object = json.loads(path.read_text(encoding="utf-8"))
    if (
        not isinstance(value, dict)
        or set(value) != {"version", "role", "private_tls_verified", "server_name"}
        or value.get("version") != 1
        or value.get("role") != "guest-standin"
        or value.get("server_name") != "llm.internal"
        or type(value.get("private_tls_verified")) is not bool
    ):
        return "invalid"
    return "verified" if value["private_tls_verified"] else "unverified"


def satellite_standin_ready() -> bool:
    """@cc [owner:ghuntley,label:verification] bootstrap-satellite-standin-channel
    Satellite setup MUST observe the independent origin fixture through its
    authenticated state read, load the published private Audi root, and find
    the guest stand-in's receipt that it completed a verified TLS handshake to
    private Audi inside Lilly's network namespace. The stand-in is not a guest:
    its receipt grants no VM binding and MUST NOT be read as guest readiness.
    Missing or invalid evidence MUST leave setup incomplete.
    """
    profile = "satellite-standin"
    try:
        origin = GitOrigin(
            os.getenv("ANTITHESIS_ORIGIN_ADMIN_URL", "http://origin:8080"),
            Path(
                os.getenv(
                    "ANTITHESIS_ORIGIN_ADMIN_TOKEN_FILE", "/run/overalls-origin-admin/admin-token"
                )
            ),
        )
        ssl.create_default_context(cafile=_required("ANTITHESIS_PRIVATE_ROOT_CA"))
        receipt = _channel_receipt(
            Path(_required("ANTITHESIS_GUEST_STANDIN_ROOT")) / "results/ready.json"
        )
    except (OSError, UnicodeError, ValueError) as error:
        return _incomplete(profile, _configuration_reason(error))
    source = origin.state()
    if source.state is not State.OBSERVED or source.value is None:
        return _incomplete(profile, f"origin_state_{source.state.value}")
    if receipt is None:
        return _incomplete(profile, "guest_standin_receipt_missing")
    if receipt != "verified":
        return _incomplete(profile, f"guest_standin_receipt_{receipt}")
    return True


def guest_lifecycle_ready() -> bool:
    """@cc [owner:ghuntley,label:verification] bootstrap-guest-substrate
    Guest-lifecycle setup MUST observe the guest-vmm image identity through the
    enrollment operator's read-only witness bridge and a Marshall catalog that
    offers that exact image with known capacity for its shape. The capacity
    comes from the labelled STUB-storage collector and MUST NOT be described as
    native ZFS or KVM readiness. Missing observations leave setup incomplete.
    """
    profile = "guest-lifecycle"
    try:
        request_root = Path(_required("ANTITHESIS_CONTROL_REQUEST_DIR"))
    except ValueError as error:
        return _incomplete(profile, f"configuration ({type(error).__name__})")
    try:
        gap = substrate_gap(request_root)
    except OSError as error:
        return _incomplete(profile, f"operator_channel ({type(error).__name__})")
    if gap is not None:
        return _incomplete(profile, gap)
    return True
