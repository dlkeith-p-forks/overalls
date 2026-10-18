"""STUB (harness) backward clock step stays scoped to the selected upload."""

import json
import tempfile
from pathlib import Path
from unittest import TestCase

from backup import helper_clock_step


class ClockStepTests(TestCase):
    def test_only_host_state_backup_steps_the_clock(self) -> None:
        self.assertTrue(
            helper_clock_step.selected(["backup", "--json", "--tag", "host-state", "--", "/x"])
        )
        for arguments in (
            [],
            ["snapshots", "--json"],
            ["backup", "--tag", "host-manifest", "--", "/x"],
            ["backup", "--tag", "guest:one", "--", "/x"],
        ):
            with self.subTest(arguments=arguments):
                self.assertFalse(helper_clock_step.selected(arguments))

    def test_configuration_requires_a_backward_whole_second_offset(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "clock-step.json"
            path.write_text(
                json.dumps({"real": "/r", "spec": "/s", "offset": "-120"}), encoding="utf-8"
            )
            self.assertEqual(helper_clock_step.load(path)["offset"], "-120")
            for offset in ("+120", "120", "-", "-1.5", 120):
                with self.subTest(offset=offset):
                    path.write_text(
                        json.dumps({"real": "/r", "spec": "/s", "offset": offset}),
                        encoding="utf-8",
                    )
                    with self.assertRaises(ValueError):
                        helper_clock_step.load(path)
