"""Small real Control/host smoke after bootstrap, tolerating injected faults."""

import logging

from antithesis.assertions import always_or_unreachable, reachable

from core.config import Config, read_fixture
from core.control import ControlClient
from core.http import HttpClient
from core.interesting import choice
from core.outcome import State
from core.sql import SqlOracle

LOG = logging.getLogger(__name__)


def run(config: Config) -> int:
    """@cc [owner:ghuntley,label:verification] smoke-real-control-boundary
    The smoke MUST call the actual fleet Control listener and independent host
    oracle. Transport/SQL unavailability MUST leave a verdict unknown, while an
    observed wrong-version response other than 426 MUST fail its assertion.
    """
    fixture = read_fixture(config.fixture_manifest)
    http = HttpClient(config.ca_file)
    oracle = SqlOracle(config)

    # No numeric menu axis: Control versions and actions are a fixed vocabulary.
    # Fresh SDK draws vary the real Marshall replica for every probe.
    for _ in range(3):
        origin = choice(config.marshall_urls)
        control = ControlClient(http, origin)
        wrong_version = control.wrong_version()
        if wrong_version.state is not State.UNAVAILABLE:
            always_or_unreachable(
                wrong_version.status == 426,
                "Control smoke wrong outer version receives terminal 426",
            )

        invalid_credential = control.invalid_credential()
        if invalid_credential.state is not State.UNAVAILABLE:
            always_or_unreachable(
                invalid_credential.status == 401,
                "Control smoke invalid credential refused before upgrade",
            )
            if invalid_credential.status == 401:
                reachable("Control smoke observed authentication refusal on fleet listener")

        for host_id in fixture.host_ids:
            host = oracle.host_authority(host_id)
            if (
                host.state is State.OBSERVED
                and host.value is not None
                and host.value.report_sequence > 0
                and host.value.connected
                and host.value.report_fresh
            ):
                reachable("Control smoke observed fresh connected host report")
    LOG.info("Control smoke chunk completed")
    return 0


def main() -> int:
    logging.basicConfig(level=logging.INFO, format="%(levelname)s %(message)s")
    try:
        return run(Config.from_environment())
    except (OSError, ValueError):
        # A missing fixture after bootstrap is a harness failure, not an
        # Antithesis-injected uncertain SUT response.
        LOG.exception("Control smoke fixture unavailable")
        return 1
