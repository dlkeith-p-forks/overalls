"""Bootstrap must fail closed and call lifecycle only after verified readiness."""

import json
import os
import sqlite3
import tempfile
import time
import unittest
from dataclasses import replace
from pathlib import Path
from threading import Event
from unittest.mock import MagicMock, patch
from uuid import uuid4

from core.bootstrap import Probe, probe, run
from core.config import Config, read_fixture
from core.outcome import State
from core.profile_readiness import (
    access_smtp_ready,
    admission_stub_ready,
    backup_restic_ready,
    guest_lifecycle_ready,
    recorder_host_ready,
    repository_origin_ready,
    satellite_standin_ready,
)
from core.sql import SqlOracle


class BootstrapTests(unittest.TestCase):
    def config(self, directory: Path, timeout: int = 1) -> Config:
        return Config(
            marshall_urls=("https://marshall-a:4443",),
            ca_file=directory / "ca.crt",
            fixture_manifest=directory / "fixture.json",
            db_host="pg",
            db_port=5432,
            db_user="oracle",
            db_name="marshall",
            db_password_file=directory / "db-password",
            timeout_seconds=timeout,
        )

    def test_missing_fixture_never_reaches_setup(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            config = self.config(Path(directory))
            self.assertEqual(probe(config), Probe(False, "fixture_or_ca"))
            with (
                patch("core.bootstrap.reachable") as reach,
                patch("core.bootstrap.setup_complete") as setup,
            ):
                self.assertEqual(run(config, Event()), 1)
            reach.assert_not_called()
            setup.assert_not_called()

    def test_setup_emitted_once_after_ready_probe(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            config = self.config(Path(directory))
            stop = Event()

            def setup_once(_details: dict[str, str]) -> None:
                stop.set()

            with (
                patch("core.bootstrap.probe", return_value=Probe(True, "complete")),
                patch("core.bootstrap.reachable") as reach,
                patch("core.bootstrap.setup_complete", side_effect=setup_once) as setup,
            ):
                self.assertEqual(run(config, stop), 0)
            reach.assert_called_once()
            setup.assert_called_once_with({"template": "control-core"})

    def test_optional_profiles_emit_exactly_one_selected_tag(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            for profile in (
                "repository-origin",
                "access-smtp",
                "recorder-host",
                "admission-stub",
                "backup-restic",
                "satellite-standin",
                "guest-lifecycle",
            ):
                with self.subTest(profile=profile):
                    config = replace(self.config(Path(directory)), profile=profile)
                    stop = Event()

                    def setup_once(_details: dict[str, str], completion: Event = stop) -> None:
                        completion.set()

                    with (
                        patch("core.bootstrap.probe", return_value=Probe(True, "complete")),
                        patch("core.bootstrap.reachable"),
                        patch("core.bootstrap.setup_complete", side_effect=setup_once) as setup,
                    ):
                        self.assertEqual(run(config, stop), 0)
                    setup.assert_called_once_with({"template": profile})

    def test_optional_profiles_fail_closed_without_selected_fixture(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            config = self.config(Path(directory))
            with patch.dict(os.environ, {}, clear=True):
                self.assertFalse(repository_origin_ready(config, "fixture-a"))
                self.assertFalse(access_smtp_ready(config, "fixture-a"))
                self.assertFalse(recorder_host_ready(config))
                self.assertFalse(backup_restic_ready())
                self.assertFalse(satellite_standin_ready())
                self.assertFalse(guest_lifecycle_ready())

    def test_guest_probe_requires_observed_substrate_and_reports_once(self) -> None:
        environment = {"ANTITHESIS_CONTROL_REQUEST_DIR": "/run/overalls-control-requests"}
        with (
            patch.dict(os.environ, environment),
            patch("core.profile_readiness.substrate_gap") as gap,
        ):
            gap.return_value = "guest_identity_unavailable"
            with self.assertLogs("core.profile_readiness", level="WARNING") as logs:
                self.assertFalse(guest_lifecycle_ready())
                self.assertFalse(guest_lifecycle_ready())
            self.assertEqual(len(logs.records), 1)
            self.assertIn("guest_identity_unavailable", logs.output[0])
            gap.side_effect = PermissionError("requests")
            with self.assertLogs("core.profile_readiness", level="WARNING") as logs:
                self.assertFalse(guest_lifecycle_ready())
            self.assertIn("operator_channel (PermissionError)", logs.output[0])
            gap.side_effect = None
            gap.return_value = None
            self.assertTrue(guest_lifecycle_ready())
            gap.assert_called_with(Path("/run/overalls-control-requests"))

    def test_backup_probe_refuses_shared_or_toolless_root(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory) / "fixture"
            root.mkdir()
            root.chmod(0o777)
            with patch.dict(os.environ, {"ANTITHESIS_BACKUP_ROOT": str(root)}, clear=True):
                # Absent image tools refuse before any repository is created.
                self.assertFalse(backup_restic_ready())
                with (
                    patch("core.profile_readiness.BACKUP_MODULES", Path(__file__)),
                    patch("core.profile_readiness.RESTIC", Path(__file__)),
                ):
                    self.assertFalse(backup_restic_ready())
            self.assertEqual(list(root.iterdir()), [])

    def test_satellite_probe_requires_verified_standin_receipt(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / "results").mkdir()
            token = root / "admin-token"
            token.write_text("t" * 40, encoding="ascii")
            environment = {
                "ANTITHESIS_ORIGIN_ADMIN_URL": "http://origin-fixture:8080",
                "ANTITHESIS_ORIGIN_ADMIN_TOKEN_FILE": str(token),
                "ANTITHESIS_PRIVATE_ROOT_CA": str(root / "missing.pem"),
                "ANTITHESIS_GUEST_STANDIN_ROOT": str(root),
            }
            observed = MagicMock()
            observed.state = State.OBSERVED
            with (
                patch.dict(os.environ, environment, clear=True),
                patch("core.profile_readiness.ssl.create_default_context"),
                patch("core.profile_readiness.GitOrigin.state", return_value=observed),
            ):
                self.assertFalse(satellite_standin_ready())
                receipt: dict[str, object] = {
                    "version": 1,
                    "role": "guest-standin",
                    "private_tls_verified": False,
                    "server_name": "llm.internal",
                }
                ready = root / "results/ready.json"
                ready.write_text(json.dumps(receipt), encoding="utf-8")
                self.assertFalse(satellite_standin_ready())
                receipt["private_tls_verified"] = True
                ready.write_text(json.dumps(receipt), encoding="utf-8")
                self.assertTrue(satellite_standin_ready())

    def test_unknown_profile_is_rejected_before_setup(self) -> None:
        environment = {
            "ANTITHESIS_BOOTSTRAP_PROFILE": "unreviewed",
            "ANTITHESIS_MARSHALL_URLS": "https://marshall-a:4443",
        }
        with (
            patch.dict(os.environ, environment, clear=True),
            self.assertRaisesRegex(ValueError, "unsupported bootstrap profile"),
        ):
            Config.from_environment()

    def test_repository_probe_requires_three_independent_reads(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            config = self.config(Path(directory))
            fixture = MagicMock()
            fixture.fixture_id = "fixture-a"
            fixture.repository_id = uuid4()
            fixture.registered_by_id = uuid4()
            fixture.owner = "fixture"
            fixture.name = "demo"
            source = MagicMock()
            source.state = State.OBSERVED
            source.value.sequence = 0
            source.value.generation = 1
            source.value.head = "a" * 40
            identity = MagicMock()
            identity.state = State.OBSERVED
            # Marshall stores the canonical lowercase source identity.
            identity.value = (("github", "fixture", "demo", fixture.registered_by_id),)
            publication = MagicMock()
            publication.state = State.OBSERVED
            publication.value.phase = "pending"
            api = MagicMock()
            api.state = State.OBSERVED
            api.status = 200
            api.value.state = "missing"
            environment = {
                "ANTITHESIS_REPOSITORY_FIXTURE_FILE": "fixture.json",
                "ANTITHESIS_ORIGIN_ADMIN_URL": "http://origin-fixture:8080",
                "ANTITHESIS_ORIGIN_ADMIN_TOKEN_FILE": "origin-token",
                "ANTITHESIS_ENRICO_URL": "https://enrico:5445",
                "ANTITHESIS_ENRICO_CA_FILE": "enrico-ca",
                "ANTITHESIS_ENRICO_TOKEN_FILE": "enrico-token",
            }
            with (
                patch.dict(os.environ, environment),
                patch("core.profile_readiness.ssl.create_default_context"),
                patch("core.profile_readiness.read_repository_fixture", return_value=fixture),
                patch("core.profile_readiness.GitOrigin") as origin,
                patch("core.profile_readiness.EnricoClient") as enrico,
                patch("core.profile_readiness.SqlOracle") as sql,
                patch("core.profile_readiness.RepositoryOracle") as repository,
            ):
                origin.return_value.state.return_value = source
                sql.return_value.select.return_value = identity
                repository.return_value.published.return_value = publication
                enrico.return_value.status.return_value = api
                self.assertTrue(repository_origin_ready(config, "fixture-a"))
                self.assertFalse(repository_origin_ready(config, "wrong-fixture"))
                source.state = State.UNAVAILABLE
                self.assertFalse(repository_origin_ready(config, "fixture-a"))
                source.state = State.OBSERVED
                identity.state = State.UNAVAILABLE
                self.assertFalse(repository_origin_ready(config, "fixture-a"))
                identity.state = State.OBSERVED
                api.state = State.UNAVAILABLE
                self.assertFalse(repository_origin_ready(config, "fixture-a"))
                api.state = State.OBSERVED
                # The manifest spelling must equal Marshall's committed identity;
                # the unmet condition is reported once per distinct reason.
                identity.value = (("github", "Fixture", "demo", fixture.registered_by_id),)
                with self.assertLogs("core.profile_readiness", level="WARNING") as logs:
                    self.assertFalse(repository_origin_ready(config, "fixture-a"))
                    self.assertFalse(repository_origin_ready(config, "fixture-a"))
                self.assertEqual(len(logs.records), 1)
                self.assertIn("sql_registration_identity_mismatch", logs.output[0])
                identity.value = (("github", "fixture", "demo", fixture.registered_by_id),)
                publication.value.phase = "failed"
                with self.assertLogs("core.profile_readiness", level="WARNING") as logs:
                    self.assertFalse(repository_origin_ready(config, "fixture-a"))
                self.assertIn("sql_publication_phase_failed", logs.output[0])
                publication.value.phase = "pending"
                self.assertTrue(repository_origin_ready(config, "fixture-a"))

    def test_access_probe_requires_all_actors_and_smtp_receipts(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            config = self.config(Path(directory))
            actors = [MagicMock() for _ in range(3)]
            for actor in actors:
                actor.user_id = uuid4()
                actor.email = f"{actor.user_id}@example.test"
            fixture = MagicMock()
            fixture.fixture_id = "fixture-a"
            fixture.admin_a, fixture.admin_b, fixture.target = actors
            account = MagicMock()
            account.state = State.OBSERVED
            account.value.deleted = False
            receipt = MagicMock()
            receipt.state = State.OBSERVED
            receipt.value = 0
            with (
                patch.dict(os.environ, {"ANTITHESIS_ACCESS_FIXTURE_FILE": "fixture.json"}),
                patch("core.profile_readiness.read_access_fixture", return_value=fixture),
                patch("core.profile_readiness.MailLinks") as mail,
                patch("core.profile_readiness.SqlOracle"),
                patch("core.profile_readiness.AccessOracle") as oracle,
            ):
                oracle.return_value.account.side_effect = [
                    self._account_observation(actor.user_id) for actor in actors
                ]
                mail.from_environment.return_value.sequence.return_value = receipt
                self.assertTrue(access_smtp_ready(config, "fixture-a"))
                self.assertFalse(access_smtp_ready(config, "wrong-fixture"))
                oracle.return_value.account.side_effect = [
                    self._account_observation(actors[0].user_id),
                    self._account_observation(uuid4()),
                ]
                self.assertFalse(access_smtp_ready(config, "fixture-a"))
                oracle.return_value.account.side_effect = [
                    self._account_observation(actor.user_id) for actor in actors
                ]
                receipt.state = State.UNAVAILABLE
                self.assertFalse(access_smtp_ready(config, "fixture-a"))

    def test_admission_stub_probe_requires_committed_stub_backed_report(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            config = self.config(Path(directory))
            host = uuid4()
            with patch("core.profile_readiness.SqlOracle") as sql:
                select = sql.return_value.select
                select.return_value = MagicMock(
                    state=State.OBSERVED, value=((True, True, True, 1, 1),)
                )
                self.assertTrue(admission_stub_ready(config, (host,)))
                self.assertEqual(select.call_args.args[1][-1], str(host))
                self.assertFalse(admission_stub_ready(config, (host, uuid4())))
                for row in (
                    (False, True, True, 1, 1),
                    (True, None, True, 1, 1),
                    (True, True, False, 1, 1),
                    (True, True, True, 0, 1),
                    (True, True, True, 1, 0),
                ):
                    with self.subTest(row=row):
                        select.return_value = MagicMock(state=State.OBSERVED, value=(row,))
                        self.assertFalse(admission_stub_ready(config, (host,)))
                select.return_value = MagicMock(state=State.OBSERVED, value=())
                self.assertFalse(admission_stub_ready(config, (host,)))
                select.return_value = MagicMock(state=State.UNAVAILABLE, value=None)
                self.assertFalse(admission_stub_ready(config, (host,)))

    def test_recorder_probe_requires_fresh_independent_witnesses(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            requests, results, observation, ledger = (
                root / "requests",
                root / "results",
                root / "observation",
                root / "ledger",
            )
            for path in (requests, results, observation, ledger):
                path.mkdir()
            producer = {"pid": 41, "uid": 990, "start_ticks": 7, "cgroup": ""}

            def write(name: str, value: object) -> None:
                (observation / name).write_text(json.dumps(value), encoding="utf-8")

            def publish(**changes: object) -> None:
                status: dict[str, object] = {
                    "sample_ns": time.time_ns(),
                    "producer": True,
                    "recorder": True,
                    "spool": True,
                    "archive": True,
                }
                if changes.get("stale"):
                    status["sample_ns"] = time.time_ns() - 60_000_000_000
                if changes.get("inactive"):
                    status["spool"] = False
                write("status.json", status)
                write(
                    "identity.json",
                    producer
                    | {
                        "cgroup": "0::/system.slice/foreign.service"
                        if changes.get("foreign")
                        else "0::/fixture.slice/recorder-peer.service"
                    },
                )
                write(
                    "spool_identity.json",
                    {
                        "pid": 52,
                        "uid": 991,
                        "start_ticks": 9,
                        "cgroup": "0::/system.slice/overalls-trace-recorder.service",
                    },
                )
                write(
                    "filesystem.json",
                    {
                        "archive_device": 2049,
                        "root_device": 2049 if changes.get("same_device") else 2050,
                        "free_bytes": 1024,
                        "total_bytes": 64 * 1024 * 1024,
                    },
                )
                owner_pid = 40 if changes.get("other_producer") else 41
                write(
                    "state.json",
                    {
                        "incarnation": "a" * 32,
                        "pending": {
                            "1": {
                                "deadline_ns": 1,
                                "producer": {"pid": owner_pid, "start_ticks": 7, "boot_id": "b"},
                            }
                        },
                    },
                )

            archive = observation / "archive.sqlite"
            with sqlite3.connect(archive) as database:
                database.execute("CREATE TABLE batches (id TEXT PRIMARY KEY)")
                database.execute("CREATE TABLE pending (id TEXT PRIMARY KEY)")
            database.close()
            environment = {
                "ANTITHESIS_RECORDER_REQUESTS": str(requests),
                "ANTITHESIS_RECORDER_RESULTS": str(results),
                "ANTITHESIS_RECORDER_OBSERVATION": str(observation),
                "ANTITHESIS_RECORDER_LEDGER": str(ledger / "ledger.sqlite"),
            }
            config = self.config(root)
            with patch.dict(os.environ, environment):
                publish()
                self.assertTrue(recorder_host_ready(config))
                for change in (
                    "stale",
                    "inactive",
                    "foreign",
                    "same_device",
                    "other_producer",
                ):
                    with self.subTest(change=change):
                        publish(**{change: True})
                        self.assertFalse(recorder_host_ready(config))
                publish()
                archive.unlink()
                self.assertFalse(recorder_host_ready(config))

    @staticmethod
    def _account_observation(user_id: object) -> MagicMock:
        observation = MagicMock()
        observation.state = State.OBSERVED
        observation.value.user_id = user_id
        observation.value.deleted = False
        return observation

    def test_fixture_rejects_duplicate_or_missing_host_identity(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "fixture.json"
            host_id = str(uuid4())
            fixture = {
                "schema_version": 1,
                "fixture_id": "synthetic-a",
                "migration_version": 20261010000000,
                "host_ids": [host_id, host_id],
            }
            path.write_text(json.dumps(fixture), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "duplicate"):
                read_fixture(path)
            fixture["host_ids"] = []
            path.write_text(json.dumps(fixture), encoding="utf-8")
            with self.assertRaisesRegex(ValueError, "invalid host"):
                read_fixture(path)

    def test_unavailable_oracle_does_not_look_like_empty_result(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            oracle = SqlOracle(self.config(Path(directory)))
            self.assertIs(oracle.select("SELECT 1").state, State.UNAVAILABLE)
            with self.assertRaisesRegex(ValueError, "SELECT"):
                oracle.select("DELETE FROM compute_hosts")

    def test_host_authority_reads_current_schema_and_validates_row(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            oracle = SqlOracle(self.config(Path(directory)))
            host_id = uuid4()
            connection = MagicMock()
            cursor = connection.__enter__.return_value.cursor.return_value.__enter__.return_value
            cursor.fetchone.return_value = (3, True, True)
            with patch.object(oracle, "_connect", return_value=connection):
                observed = oracle.host_authority(host_id)
                self.assertIs(observed.state, State.OBSERVED)
                authority = observed.value
                self.assertIsNotNone(authority)
                if authority is None:
                    self.fail("observed host authority was absent")
                self.assertEqual(authority.host_id, host_id)
                self.assertEqual(authority.report_sequence, 3)
                self.assertTrue(authority.connected)
                self.assertTrue(authority.report_fresh)
                statement = cursor.execute.call_args.args[0]
                self.assertIn("SELECT h.report_sequence", statement)
                self.assertIn("s.id = h.connection_session_id", statement)
                self.assertIn("s.host_id = h.id", statement)
                self.assertIn("s.epoch = h.connection_epoch", statement)
                self.assertIn("h.reported_at <= now()", statement)
                self.assertNotIn("protocol_version", statement)

                cursor.fetchone.return_value = (3, True, "unknown")
                self.assertIs(oracle.host_authority(host_id).state, State.UNAVAILABLE)


if __name__ == "__main__":
    unittest.main()
