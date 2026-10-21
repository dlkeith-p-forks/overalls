"""Isolated measurement fixtures; these do not establish fleet or ZFS acceptance."""

import copy
import importlib.util
import json
import sys
import tempfile
import unittest
import uuid
from pathlib import Path
from unittest.mock import patch

spec = importlib.util.spec_from_file_location("fleet_metrics", sys.argv.pop(1))
if spec is None or spec.loader is None:
    raise RuntimeError("fleet metrics helper unavailable")
m = importlib.util.module_from_spec(spec)
spec.loader.exec_module(m)
sys.modules["metrics"] = m
runtime_path = sys.argv.pop(1)
sys.path.insert(0, str(Path(runtime_path).parent))
runtime_spec = importlib.util.spec_from_file_location("fleet_runtime", runtime_path)
if runtime_spec is None or runtime_spec.loader is None:
    raise RuntimeError("fleet runtime helper unavailable")
r = importlib.util.module_from_spec(runtime_spec)
runtime_spec.loader.exec_module(r)
PLACEMENT = "11111111-2222-3333-4444-555555555555"


class MetricsTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.reader = m.Reader(self.root)

    def write(self, path: str, content: str) -> None:
        destination = self.root / path.lstrip("/")
        destination.parent.mkdir(parents=True, exist_ok=True)
        destination.write_text(content)

    def test_brady_snapshot_requires_fresh_service_and_closed_metrics(self) -> None:
        invocation = "a" * 32
        workloads = [
            {"unit": "brady.service", "invocation_id": invocation, "active_state": "active"}
        ]
        data = {
            "version": 1,
            "sampled_at": 100,
            "invocation_id": invocation,
            "incarnation": "b" * 32,
            "gauges": {"cache_writable": 0},
            "counters": {"requests": 10},
        }
        self.write("/run/brady/metrics.json", json.dumps(data))
        row = r.brady_metrics(self.reader, workloads, 105)
        self.assertEqual(row["counters"], {"requests": 10})
        self.assertEqual(row["gauges"], {"cache_writable": 0})
        row = r.brady_metrics(self.reader, workloads, 140)
        self.assertEqual(row["counters"], {"requests": 10})
        with self.assertRaises(ValueError):
            r.brady_metrics(self.reader, workloads, 146)
        with self.assertRaises(ValueError):
            r.brady_metrics(self.reader, [], 105)
        with self.assertRaises(ValueError):
            r.brady_metrics(self.reader, [dict(workloads[0], active_state="failed")], 105)
        for field, value in (
            ("invocation_id", "c" * 32),
            ("counters", {"signed_url": 1}),
            ("counters", {"requests": True}),
            ("gauges", {"cache_writable": 2}),
        ):
            invalid = dict(data, **{field: value})
            self.write("/run/brady/metrics.json", json.dumps(invalid))
            with self.assertRaises(ValueError):
                r.brady_metrics(self.reader, workloads, 105)

    def test_brady_collected_rates_do_not_span_counter_restarts_or_missing_snapshots(self) -> None:
        rates = m.Rates()
        invocation = "a" * 32
        workloads = [
            {"unit": "brady.service", "invocation_id": invocation, "active_state": "active"}
        ]

        def sample(
            requests: int,
            clock: int,
            incarnation: str = "b" * 32,
            gauges: dict[str, int] | None = None,
        ) -> dict[str, object]:
            data = {
                "version": 1,
                "sampled_at": clock,
                "invocation_id": invocation,
                "incarnation": incarnation,
                "gauges": gauges or {},
                "counters": {"requests": requests},
            }
            self.write("/run/brady/metrics.json", json.dumps(data))
            row = r.brady_metrics(self.reader, workloads, clock)
            return rates.apply([row], "boot", clock)[0]

        self.assertEqual(sample(100, 100)["rates"], {})
        self.assertEqual(sample(110, 105)["rates"], {"requests": 2})
        # An OTP producer can restart without changing the systemd invocation.
        # Even a higher counter in the new process must not bridge incarnations.
        self.assertEqual(sample(200, 110, "c" * 32)["rates"], {})
        self.assertEqual(sample(210, 115, "c" * 32)["rates"], {"requests": 2})
        rates.apply([], "boot", 120)
        self.assertEqual(sample(230, 125, "c" * 32)["rates"], {})
        row = sample(230, 130, "c" * 32, {"cache_writable": 0})
        self.assertEqual(row["rates"], {"requests": 0})
        self.assertEqual(row["gauges"], {"cache_writable": 0})
        self.assertEqual(sample(230, 135, "c" * 32)["gauges"], {})

    def test_host_unknown_memory_pressure_and_cpu_guest_accounting(self) -> None:
        self.write(
            "/proc/stat", "cpu 100 0 40 400 10 0 0 0 20 0\ncpu0 100 0 40 400 10 0 0 0 20 0\n"
        )
        self.write(
            "/proc/meminfo",
            "MemTotal: 100 kB\nMemAvailable: 20 kB\nSwapFree: 0 kB\nCached: broken kB\n",
        )
        self.write("/proc/loadavg", "0.25 0.5 1.0 1/100 999\n")
        self.write("/proc/vmstat", "oom_kill 0\npswpin -1\n")
        self.write("/proc/pressure/cpu", "some avg10=0.25 avg60=0.00 avg300=0.00 total=1250\n")
        rows = m.host_metrics(self.reader)
        host = rows[0]
        self.assertEqual(host["gauges"]["memory_used_bytes"], 81920)
        self.assertEqual(host["gauges"]["SwapFree_bytes"], 0)
        self.assertNotIn("Cached_bytes", host["gauges"])
        self.assertNotIn("pswpin", host["counters"])
        self.assertEqual(host["counters"]["oom_kill"], 0)
        self.assertEqual(host["gauges"]["psi_cpu_some_avg10_percent"], 0.25)
        self.assertNotIn("psi_memory_some_avg10_percent", host["gauges"])
        rates = m.Rates(ticks=100)
        rates.apply(rows, "boot", 1)
        self.write(
            "/proc/stat", "cpu 140 0 50 450 10 0 0 0 30 0\ncpu0 140 0 50 450 10 0 0 0 30 0\n"
        )
        cpu = rates.apply(m.host_metrics(self.reader), "boot", 2)[1]
        self.assertEqual(cpu["gauges"]["cpu_user_percent"], 30)
        self.assertEqual(cpu["gauges"]["cpu_guest_percent"], 10)
        self.assertEqual(cpu["gauges"]["cpu_busy_cores"], 0.5)
        self.assertEqual(sum(v for k, v in cpu["gauges"].items() if k.endswith("_percent")), 100)

    def test_rates_reject_resets_gaps_boot_changes_and_identity_reuse(self) -> None:
        rates = m.Rates()

        def sample(
            value: int,
            clock: int,
            boot: str = "boot",
            incarnation: str | None = "1",
        ) -> object:
            row = m.record(
                "disk", "8:0", {"incarnation": incarnation}, counters={"read_ops": value}
            )
            return rates.apply([row], boot, clock)[0]["rates"]

        self.assertEqual(sample(10, 0), {})
        self.assertEqual(sample(20, 5), {"read_ops": 2})
        self.assertEqual(sample(20, 10), {"read_ops": 0})
        self.assertEqual(sample(2, 15), {})
        self.assertEqual(sample(3, 15), {})
        self.assertEqual(sample(10, 50), {})
        self.assertEqual(sample(20, 55, incarnation="2"), {})
        self.assertEqual(sample(30, 60, boot="next", incarnation="2"), {})
        self.assertEqual(sample(40, 65, boot="next", incarnation=None), {})
        rates.apply([], "next", 70)
        self.assertEqual(sample(50, 75, boot="next", incarnation="2"), {})

    def test_disk_network_classification_and_private_field_exclusion(self) -> None:
        self.write(
            "/proc/diskstats",
            "8 0 sda 1 0 8 4 2 0 16 8 0 10 12\n8 1 sda1 1 0 8 4 2 0 16 8 0 10 12\n",
        )
        self.write("/sys/class/block/sda/device/fixture", "")
        self.write("/sys/class/block/sda/diskseq", "12\n")
        self.write("/sys/class/block/sda1/partition", "1\n")
        self.write(
            "/proc/net/dev",
            "eth0: 100 2 0 0 0 0 0 0 200 3 0 0 0 0 0 0\ntap0: 300 4 0 0 0 0 0 0 400 5 0 0 0 0 0 0\n",
        )
        self.write("/sys/class/net/eth0/ifindex", "2\n")
        self.write("/sys/class/net/tap0/ifindex", "3\n")
        rows = m.device_metrics(
            self.reader,
            ["eth0"],
            {
                "tap0": {
                    "placement_id": PLACEMENT,
                    "execution_epoch": 7,
                    "secret": "private-fixture",
                }
            },
        )
        self.assertTrue(rows[0]["context"]["physical"])
        self.assertTrue(rows[1]["context"]["partition"])
        self.assertEqual(rows[0]["context"]["sector_bytes"], 512)
        self.assertEqual(rows[2]["context"]["scope"], "external")
        self.assertEqual(rows[3]["context"]["scope"], "vm")
        self.assertEqual(rows[3]["context"]["execution_epoch"], 7)
        self.assertNotIn("private-fixture", json.dumps(rows))

    def test_workloads_require_placement_epoch_and_invocation(self) -> None:
        unit = f"lilly-vm-{PLACEMENT}.service"
        path = f"/sys/fs/cgroup/lilly.slice/{unit}"
        self.write(path + "/cpu.stat", "usage_usec 5000000\nnr_throttled 10\nthrottled_usec 1000\n")
        self.write(path + "/cpu.max", "200000 100000\n")
        self.write(path + "/memory.current", "4096\n")
        self.write(path + "/memory.max", "max\n")
        self.write(path + "/memory.events", "oom_kill 0\n")
        self.write(path + "/io.stat", "8:0 rbytes=512 wbytes=1024 rios=1 wios=2 secret=123\n")
        workload = {
            "kind": "vm",
            "unit": unit,
            "placement_id": PLACEMENT,
            "execution_epoch": 2,
            "invocation_id": "a" * 32,
        }
        rows = m.cgroup_metrics(self.reader, [workload])
        self.assertEqual(rows[-1]["gauges"]["cpu_limit_cores"], 2)
        self.assertNotIn("memory_max_bytes", rows[-1]["gauges"])
        self.assertTrue(rows[-1]["context"]["memory_max_unlimited"])
        self.assertNotIn("secret", rows[0]["counters"])
        for field, bad in (
            ("execution_epoch", -1),
            ("placement_id", "../escape"),
            ("invocation_id", None),
            ("unit", "../escape.service"),
        ):
            self.assertEqual(m.cgroup_metrics(self.reader, [dict(workload, **{field: bad})]), [])
        changed = copy.deepcopy(workload)
        changed["invocation_id"] = "b" * 32
        rate = m.Rates()
        rate.apply(rows, "boot", 0)
        self.assertEqual(
            rate.apply(m.cgroup_metrics(self.reader, [changed]), "boot", 5)[-1]["rates"], {}
        )

    def test_zfs_physical_logical_and_unlimited_are_distinct(self) -> None:
        self.assertTrue(m.valid_guid(str(2**64 - 1)))
        self.assertFalse(m.valid_guid(str(2**64)))
        rows = m.zfs_metrics(
            "123\ttank\t1000\t400\t600\t5\t40\tONLINE\n",
            "456\ttank/vms\t400\t600\t200\t800\t400\t100\t200\t100\t0\t0\t1000\t2.00x\n",
        )
        self.assertEqual(rows[0]["kind"], "zpool")
        dataset = rows[1]
        self.assertEqual(dataset["gauges"]["logical_used_bytes"], 800)
        self.assertEqual(dataset["gauges"]["snapshots_used_bytes"], 100)
        self.assertEqual(dataset["gauges"]["compression_ratio"], 2)
        self.assertTrue(dataset["context"]["quota_unlimited"])
        self.assertFalse(dataset["context"]["refquota_unlimited"])
        self.assertEqual(dataset["context"]["parent"], "tank")

    def test_identity_and_bounded_inputs(self) -> None:
        raw = "0123456789abcdef0123456789abcdef"
        identity = m.host_identity(raw)
        self.assertEqual(identity, m.host_identity(raw + "\n"))
        self.assertTrue(identity.startswith("sha256:"))
        self.assertNotIn(raw, identity)
        for invalid in ("0" * 32, "uninitialized", raw + "\nextra"):
            with self.assertRaises(ValueError):
                m.host_identity(invalid)
        self.write("/oversized", "0" * (m.MAX_FILE + 1))
        self.assertEqual(self.reader.read("/oversized"), "")
        self.assertIn("/oversized", self.reader.missing)
        with self.assertRaises(ValueError):
            self.reader.path("/../escape")
        for invalid in ("NaN", "inf", "-1", str(2**64)):
            self.assertIsNone(m.finite(invalid))


class RuntimeTest(unittest.TestCase):
    def setUp(self) -> None:
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)

    def test_metadata_requires_launched_identity_and_exact_unit_cgroup(self) -> None:
        output = f"Id=lilly-vm-{PLACEMENT}.service\nInvocationID={'a' * 32}\nDescription=Overalls VM v1 placement={PLACEMENT} epoch=7 generation=9\nControlGroup=/lilly.slice/lilly-vm-{PLACEMENT}.service\nEnvironment=private-fixture\n"
        rows = r.parse_units(output, [])
        self.assertEqual(rows[0]["execution_epoch"], 7)
        self.assertEqual(rows[0]["generation"], 9)
        self.assertNotIn("private-fixture", json.dumps(rows))
        self.assertEqual(r.parse_units(output.replace("/lilly.slice/", "/system.slice/"), []), [])
        self.assertEqual(r.parse_units(output.replace("epoch=7", "epoch=0"), []), [])
        self.assertEqual(r.parse_units(output.replace("Overalls VM v1", "older unit"), []), [])
        service = (
            "Id=marshall.service\nInvocationID="
            + "b" * 32
            + "\nControlGroup=/system.slice/marshall.service\n"
        )
        self.assertEqual(r.parse_units(service, []), [])
        self.assertEqual(r.parse_units(service, ["marshall.service"])[0]["kind"], "service")

    def test_updater_status_is_bounded_and_attached_only_to_updater_service(self) -> None:
        status = self.root / "var/lib/overalls-auto-update/status.json"
        status.parent.mkdir(parents=True)
        status.write_text(
            json.dumps(
                {
                    "phase": "healthy",
                    "candidate": {"revision": "c" * 40, "repository": "private", "branch": "main"},
                    "lastHealthy": {
                        "revision": "a" * 40,
                        "repository": "private",
                        "branch": "main",
                    },
                    "failure": "secret-value",
                }
            )
        )
        values = r.updater_status(m.Reader(self.root))
        self.assertEqual(values["deployment_revision"], "a" * 40)
        self.assertEqual(values["intended_deployment_revision"], "c" * 40)
        self.assertEqual(values["updater_phase"], "healthy")
        self.assertNotIn("secret-value", json.dumps(values))
        service = (
            "Id=overalls-auto-update.service\nInvocationID="
            + "c" * 32
            + "\nActiveState=active\nSubState=running\nControlGroup=/system.slice/overalls-auto-update.service\n"
        )
        rows = r.parse_units(service, ["overalls-auto-update.service"])
        self.assertEqual(rows[0]["active_state"], "active")
        rows[0].update(values)
        self.assertEqual(rows[0]["deployment_revision"], "a" * 40)

    def test_updater_observation_exists_without_active_cgroup_and_invalid_is_unknown(self) -> None:
        path = self.root / "var/lib/overalls-auto-update/status.json"
        path.parent.mkdir(parents=True)
        path.write_text(
            json.dumps({"phase": "healthy", "updatedAt": 100, "failures": 0, "failure": None})
        )
        row = r.updater_observation(m.Reader(self.root), 110)
        self.assertEqual(row["kind"], "updater")
        self.assertEqual(row["gauges"]["status_valid"], 1)
        self.assertEqual(row["gauges"]["failures"], 0)
        self.assertEqual(
            r.updater_observation(m.Reader(self.root), 3701)["gauges"]["status_valid"], 0
        )
        path.write_text(json.dumps({"phase": "healthy", "updatedAt": 100, "failures": -1}))
        self.assertEqual(
            r.updater_observation(m.Reader(self.root), 110)["gauges"], {"status_valid": 0}
        )
        path.write_text(json.dumps({"phase": "private-secret", "updatedAt": 100}))
        self.assertEqual(
            r.updater_observation(m.Reader(self.root), 110)["context"], {"updater_phase": "unknown"}
        )

    def test_proxy_metrics_are_closed_host_bound_and_unknown_on_failure(self) -> None:
        config = {
            "curl": "curl",
            "ziggy": {"socket": "/run/ziggy/proxy.sock", "host_id": PLACEMENT},
        }
        metrics = dict.fromkeys(r.ZIGGY_GAUGES, 0)
        metrics["ziggy_spool_capacity"] = 65536
        payload = dict(version=1, host_id=PLACEMENT, gauges=metrics)
        health = dict(version=1, host_id=PLACEMENT, role="ziggy", ready=False)
        with patch.object(r, "command", side_effect=[json.dumps(payload), json.dumps(health)]):
            self.assertEqual(r.ziggy_metrics(config), dict(metrics, ziggy_ready=0))
        with patch.object(r, "command", side_effect=TimeoutError()):
            self.assertEqual(r.ziggy_metrics(config), {})
        for invalid in [
            dict(payload, host_id=str(uuid.uuid4())),
            dict(payload, gauges=dict(metrics, api_key="synthetic")),
            dict(payload, gauges=dict(metrics, ziggy_active_requests=-1)),
            dict(payload, gauges=dict(metrics, ziggy_catalog_ready=2)),
        ]:
            with patch.object(r, "command", return_value=json.dumps(invalid)):
                self.assertEqual(r.ziggy_metrics(config), {})
        with patch.object(r, "command", side_effect=[json.dumps(payload), TimeoutError()]):
            self.assertEqual(r.ziggy_metrics(config), metrics)

    def test_commands_enforce_output_and_time_bounds(self) -> None:
        self.assertEqual(r.command([sys.executable, "-c", "print('ready')"]), "ready\n")
        with self.assertRaises(ValueError):
            r.command([sys.executable, "-c", "import sys; sys.stdout.write('x' * 3000000)"])
        with self.assertRaises(TimeoutError):
            r.command([sys.executable, "-c", "import time; time.sleep(10)"], timeout=0.05)


unittest.main()
