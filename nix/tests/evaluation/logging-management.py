"""Check idempotent management intent independently of production AWS credentials."""

import importlib.util
import sys
from collections.abc import Callable
from types import ModuleType, SimpleNamespace
from typing import cast

sys.modules["boto3"] = ModuleType("boto3")
spec = importlib.util.spec_from_file_location("manage", sys.argv[1])
if spec is None or spec.loader is None:
    raise RuntimeError("manage helper unavailable")
manage = importlib.util.module_from_spec(spec)
spec.loader.exec_module(manage)


class Existing(Exception):
    pass


class Client:
    exceptions = SimpleNamespace(ResourceAlreadyExistsException=Existing)

    def __init__(self) -> None:
        self.calls: list[tuple[str, dict[str, object]]] = []
        self.groups: set[object] = set()

    def create_log_group(self, **values: object) -> None:
        if values["logGroupName"] in self.groups:
            raise Existing()
        self.groups.add(values["logGroupName"])
        self.calls.append(("create_log_group", values))

    def __getattr__(self, name: str) -> Callable[..., object]:
        return lambda **values: self.calls.append((name, values))


logs, metrics = Client(), Client()
settings = dict(
    environment="fixture",
    region="us-east-1",
    partition="aws",
    accountId="123456789012",
    groups={
        "audit": "/fixture/audit",
        "operations": "/fixture/operations",
        "metrics": "/fixture/metrics",
    },
    retentionDays={"audit": 30},
    kmsKeyArn=None,
    expectedHosts=["a" * 32],
    alarmActions=[],
    queueAlarmBytes=8000,
)
manage.reconcile(logs, metrics, settings)
manage.reconcile(logs, metrics, settings)
assert len(logs.groups) == 3
assert sum(name == "create_log_group" for name, _ in logs.calls) == 3
assert any(
    name == "put_retention_policy" and data["retentionInDays"] == 90 for name, data in logs.calls
)
assert any(
    name == "tag_resource"
    and cast("dict[str, object]", data["tags"])["sensitivity"] == "restricted"
    for name, data in logs.calls
)
assert any(
    name == "put_metric_alarm" and data["TreatMissingData"] == "breaching"
    for name, data in metrics.calls
)
assert any(
    name == "put_metric_alarm" and "DroppedRecords" in cast(str, data["AlarmName"])
    for name, data in metrics.calls
)
print("CloudWatch management reconciliation, retention, sensitivity tags and alarms passed")
