import json
import shlex
from dataclasses import dataclass
from datetime import UTC, datetime, timedelta

from hypothesis import given, settings
from hypothesis import strategies as st


@dataclass(frozen=True)
class DeliveredAlert:
    name: str
    slo: str
    window: str
    status: str


def delivery_object(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise AssertionError("invalid webhook object")
    result: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            raise AssertionError("invalid webhook key")
        result[key] = item
    return result


def delivered_alerts() -> list[DeliveredAlert]:
    code, output = machine.execute("cat /var/lib/burn-webhook/received.jsonl")
    if code:
        return []
    result: list[DeliveredAlert] = []
    for line in output.splitlines():
        if not line.strip():
            continue
        body = delivery_object(json.loads(line))
        assert body.get("receiver") == "fleet-burn"
        alerts = body.get("alerts")
        assert isinstance(alerts, list)
        for value in alerts:
            alert = delivery_object(value)
            labels = delivery_object(alert.get("labels"))
            fields = [
                labels.get("alertname"),
                labels.get("slo"),
                labels.get("window"),
                alert.get("status"),
            ]
            assert all(isinstance(field, str) for field in fields)
            name, slo, window, status = fields
            assert isinstance(name, str) and isinstance(slo, str)
            assert isinstance(window, str) and isinstance(status, str)
            assert labels.get("status") == "provisional" and labels.get("severity") == "warning"
            result.append(DeliveredAlert(name, slo, window, status))
    return result


def wait_delivery(name: str, status: str) -> None:
    for _ in range(180):
        if any(alert.name == name and alert.status == status for alert in delivered_alerts()):
            return
        machine.sleep(1)
    machine.succeed(
        "curl -fsS http://127.0.0.1:9093/metrics | grep -E 'notifications|alerts_received'"
    )
    machine.execute("journalctl -u nginx.service -u burn-webhook.service --no-pager -n 30")
    raise AssertionError("expected bounded webhook delivery did not arrive")


def submit(name: str, slo: str, window: str, *, resolved: bool = False) -> None:
    now = datetime.now(UTC)
    alert: dict[str, object] = {
        "labels": {
            "alertname": name,
            "slo": slo,
            "window": window,
            "status": "provisional",
            "severity": "warning",
        },
        "startsAt": (now - timedelta(minutes=2)).isoformat(),
        "endsAt": (now + timedelta(minutes=-1 if resolved else 10)).isoformat(),
    }
    machine.succeed(
        "curl -fsS -H 'Content-Type: application/json' --data-binary "
        + shlex.quote(json.dumps([alert]))
        + " http://127.0.0.1:9093/api/v2/alerts"
    )


start_all()
machine.wait_for_unit("nginx.service")
machine.wait_for_unit("burn-webhook.service")
machine.wait_for_unit("alertmanager.service")
machine.wait_until_succeeds("curl -fsS http://127.0.0.1:9093/-/ready")
machine.wait_for_unit("prometheus.service")

with subtest("generated routing histories preserve exact roster and label refusals"):
    roster_value: object = json.loads(machine.succeed("cat /etc/burn-fixture-roster.json"))
    assert isinstance(roster_value, list)
    roster: list[str] = []
    for source in roster_value:
        assert isinstance(source, str)
        roster.append(source)
    assert len(roster) == 20

    @settings(max_examples=80, deadline=None, derandomize=True)
    @given(
        source=st.sampled_from(roster),
        window=st.sampled_from(["fast", "slow"]),
        changed=st.sampled_from(["alertname", "slo", "window", "status", "severity"]),
        foreign=st.text(alphabet="abcdefghijklmnopqrstuvwxyz0123456789_", min_size=1, max_size=24),
    )
    def routing_property(source: str, window: str, changed: str, foreign: str) -> None:
        labels: dict[str, str] = {
            "alertname": f"OverallsSLOBurn_{window}_{source}",
            "slo": source,
            "window": window,
            "status": "provisional",
            "severity": "warning",
        }
        command = "amtool --alertmanager.url=http://127.0.0.1:9093 config routes test "
        args = " ".join(shlex.quote(f"{key}={value}") for key, value in labels.items())
        machine.succeed(command + "--verify.receivers=fleet-burn " + args)
        labels[changed] = "foreign_" + foreign
        args = " ".join(shlex.quote(f"{key}={value}") for key, value in labels.items())
        machine.succeed(command + "--verify.receivers=unrouted " + args)

    routing_property()

with subtest("actual Prometheus sends a warning through verified TLS and runtime bearer custody"):
    wait_delivery("OverallsSLOBurn_fast_galileo", "firing")
    machine.succeed("ss -lnt | grep '127.0.0.1:9093'")
    machine.fail(r"ss -lnt | grep -E '(0.0.0.0|\[::\]):9093|:9094'")
    machine.fail("runuser -u nobody -- cat /run/burn-fixture/token")
    machine.fail("runuser -u nobody -- cat /run/credentials/alertmanager.service/webhook-token")

with subtest("out-of-roster and mismatched labels never reach the webhook"):
    submit("UnreviewedAlert", "galileo", "fast")
    submit("OverallsSLOBurn_slow_galileo", "foreign", "slow")
    machine.sleep(5)
    assert all(
        alert.name != "UnreviewedAlert" and alert.slo != "foreign" for alert in delivered_alerts()
    )

with subtest("receiver outage retries without claiming successful delivery"):
    # Isolate the reviewed slow warning: no firing/resolved repeat from the
    # continuously evaluated fast fixture may account for the failure counter.
    machine.succeed("systemctl stop prometheus.service")
    submit("OverallsSLOBurn_fast_galileo", "galileo", "fast", resolved=True)
    wait_delivery("OverallsSLOBurn_fast_galileo", "resolved")
    machine.succeed("touch /var/lib/burn-webhook/reject")
    submit("OverallsSLOBurn_slow_galileo", "galileo", "slow")
    machine.wait_until_succeeds("test -s /var/lib/burn-webhook/attempts")
    machine.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:9093/metrics | "
        "awk '/^alertmanager_notifications_failed_total.*webhook/ {if ($NF > 0) found=1} "
        "END {exit !found}'"
    )
    assert all(alert.name != "OverallsSLOBurn_slow_galileo" for alert in delivered_alerts())
    machine.succeed("rm /var/lib/burn-webhook/reject")
    wait_delivery("OverallsSLOBurn_slow_galileo", "firing")
    submit("OverallsSLOBurn_slow_galileo", "galileo", "slow", resolved=True)
    wait_delivery("OverallsSLOBurn_slow_galileo", "resolved")
    machine.succeed("systemctl start prometheus.service")
    machine.wait_for_unit("prometheus.service")

with subtest("native restart restores delivery and unsafe transport refuses startup"):
    machine.succeed("systemctl restart alertmanager.service")
    machine.wait_for_unit("alertmanager.service")
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:9093/-/ready")
    submit("OverallsSLOBurn_fast_audi_dns", "audi_dns", "fast")
    wait_delivery("OverallsSLOBurn_fast_audi_dns", "firing")
    machine.succeed("printf '%s\n' http://notify.test/notify > /run/burn-fixture/url")
    machine.fail("systemctl restart alertmanager.service")
    machine.succeed("printf '%s\n' https://notify.test:8443/notify > /run/burn-fixture/url")
    machine.succeed("systemctl restart alertmanager.service")
    machine.wait_for_unit("alertmanager.service")
    machine.wait_until_succeeds("curl -fsS http://127.0.0.1:9093/-/ready")
    machine.fail("journalctl -u alertmanager.service --no-pager | grep synthetic-delivery-token")
