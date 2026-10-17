"""The sole, long-lived owner of Antithesis setup signaling."""

import logging
import signal
from dataclasses import dataclass
from threading import Event
from time import monotonic

from antithesis.assertions import reachable
from antithesis.lifecycle import setup_complete

from core.config import PROFILES, Config, read_fixture
from core.http import HttpClient
from core.outcome import State
from core.profile_readiness import (
    access_smtp_ready,
    admission_stub_ready,
    backup_restic_ready,
    recorder_host_ready,
    repository_origin_ready,
    satellite_standin_ready,
)
from core.sql import SqlOracle

LOG = logging.getLogger(__name__)


@dataclass(frozen=True)
class Probe:
    ready: bool
    stage: str


def probe(config: Config) -> Probe:
    """@cc [owner:ghuntley,label:verification] bootstrap-real-readiness
    Every template MUST require the issued fixture, migrated
    primary, fresh connected host report and every declared Marshall HTTPS endpoint.
    An unavailable oracle or endpoint MUST delay setup; host reporting MUST NOT
    be represented as physical execution readiness or capacity admission. Selected
    optional profiles MUST also satisfy their independent profile probe.
    """
    try:
        fixture = read_fixture(config.fixture_manifest)
        http = HttpClient(config.ca_file)
    except (OSError, ValueError):
        return Probe(False, "fixture_or_ca")

    oracle = SqlOracle(config)
    migration = oracle.migrated_primary(fixture.migration_version)
    if migration.state is not State.OBSERVED or migration.value is not True:
        return Probe(False, "database_or_migration")

    for origin in config.marshall_urls:
        response = http.request("GET", f"{origin}/health/ready")
        if (
            response.state is not State.OBSERVED
            or response.value is None
            or response.value.status != 200
            or response.value.body != b"ok\n"
        ):
            return Probe(False, "marshall_readiness")

    for host_id in fixture.host_ids:
        observed = oracle.host_authority(host_id)
        if observed.state is not State.OBSERVED or observed.value is None:
            return Probe(False, "host_authority")
        host = observed.value
        if host.report_sequence < 1 or not host.connected or not host.report_fresh:
            return Probe(False, "host_connection_or_report")
    if config.profile not in PROFILES:
        return Probe(False, "invalid_profile")
    if config.profile == "repository-origin" and not repository_origin_ready(
        config, fixture.fixture_id
    ):
        return Probe(False, "repository_origin")
    if config.profile == "access-smtp" and not access_smtp_ready(config, fixture.fixture_id):
        return Probe(False, "access_smtp")
    if config.profile == "recorder-host" and not recorder_host_ready(config):
        return Probe(False, "recorder_host")
    if config.profile == "admission-stub" and not admission_stub_ready(config, fixture.host_ids):
        return Probe(False, "admission_stub")
    if config.profile == "backup-restic" and not backup_restic_ready():
        return Probe(False, "backup_restic")
    if config.profile == "satellite-standin" and not satellite_standin_ready():
        return Probe(False, "satellite_standin")
    return Probe(True, "complete")


def run(config: Config, stop: Event) -> int:
    """@cc [owner:ghuntley,label:verification] setup-complete-single-owner
    This process MUST emit setup_complete exactly once, only after probe succeeds,
    and remain alive afterward. Timeout, crash or signal before that point MUST
    leave setup incomplete and exit nonzero; Compose MUST NOT restart this owner.
    """
    deadline = monotonic() + config.timeout_seconds
    previous_stage = ""
    while not stop.is_set():
        result = probe(config)
        if result.ready:
            # Static literal: the Python catalog scanner must see this marker.
            reachable("Overalls bootstrap observed Control connection and independent oracle")
            if config.profile == "repository-origin":
                setup_complete({"template": "repository-origin"})
            elif config.profile == "access-smtp":
                setup_complete({"template": "access-smtp"})
            elif config.profile == "recorder-host":
                setup_complete({"template": "recorder-host"})
            elif config.profile == "admission-stub":
                setup_complete({"template": "admission-stub"})
            elif config.profile == "backup-restic":
                setup_complete({"template": "backup-restic"})
            elif config.profile == "satellite-standin":
                setup_complete({"template": "satellite-standin"})
            elif config.profile == "control-core":
                setup_complete({"template": "control-core"})
            else:
                raise ValueError("unsupported bootstrap profile")
            LOG.info("Antithesis setup complete")
            stop.wait()
            return 0
        if result.stage != previous_stage:
            LOG.info("Waiting for bootstrap stage: %s", result.stage)
            previous_stage = result.stage
        if monotonic() >= deadline:
            LOG.error("Antithesis bootstrap timed out at stage: %s", result.stage)
            return 1
        stop.wait(1.0)
    LOG.error("Antithesis bootstrap stopped before setup completed")
    return 1


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    stop = Event()

    def terminate(_signum: int, _frame: object) -> None:
        stop.set()

    signal.signal(signal.SIGTERM, terminate)
    signal.signal(signal.SIGINT, terminate)
    try:
        return run(Config.from_environment(), stop)
    except (OSError, ValueError):
        LOG.exception("Invalid Antithesis workload configuration")
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
