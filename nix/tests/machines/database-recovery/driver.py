"""Require bounded recovery of an observed lock convoy after client machine loss."""

import ipaddress
import json
import os
import random
import shlex
import time
from collections.abc import Callable
from itertools import permutations
from pathlib import Path
from tempfile import TemporaryDirectory


def fields(value: object) -> dict[str, object]:
    assert isinstance(value, dict)
    result: dict[str, object] = {}
    for key, item in value.items():
        assert isinstance(key, str)
        result[key] = item
    return result


def sql(statement: str) -> str:
    return db.succeed(
        "sudo -u postgres psql --no-psqlrc -d marshall -Atc " + shlex.quote(statement)
    ).strip()


def eventually(probe: Callable[[], bool], timeout: float) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if probe():
            return True
        time.sleep(0.2)
    return False


# @cc [owner:ghuntley,label:verification] database-recovery-drop-observed
# Silent-loss cases MUST retain positive DROP counters for the fault direction.
# Firewall installation alone MUST NOT establish exercised packet loss. Decode
# only validated fixture counters; never include connection payloads in output.
def drop_counters() -> dict[str, int]:
    parsed: object = json.loads(db.succeed("nft -j list table inet recovery_loss"))
    entries = fields(parsed)["nftables"]
    assert isinstance(entries, list)
    result: dict[str, int] = {}
    for entry in entries:
        value = fields(entry)
        if "rule" not in value:
            continue
        rule = fields(value["rule"])
        chain = rule["chain"]
        assert isinstance(chain, str) and chain in {"inbound", "outbound"}
        expressions = rule["expr"]
        assert isinstance(expressions, list)
        for expression in expressions:
            part = fields(expression)
            if "counter" in part:
                packets = fields(part["counter"])["packets"]
                assert type(packets) is int and packets >= 0 and chain not in result
                result[chain] = packets
    expected = {"inbound", "outbound"} if fault_mode == "silent" else {"inbound"}
    assert set(result) == expected
    return result


start_all()
db.wait_for_unit("postgresql.service")
m1.wait_for_unit("multi-user.target")
m1.succeed("install -d -m 700 /var/lib/overalls-fleet")
with TemporaryDirectory(prefix="database-recovery-private-") as directory:
    os.chmod(directory, 0o700)
    for filename in ["marshall.env", "ca.crt"]:
        target = "/var/lib/overalls-fleet/" + filename
        db.copy_from_machine(target, directory)
        source = Path(directory) / filename
        os.chmod(source, 0o600)
        m1.copy_from_host(str(source), target)

orders = list(permutations((1, 2, 3)))
random.Random(126).shuffle(orders)
history_index = {"crash": 0, "silent": 1, "asymmetric": 2}[fault_mode]
if expected_holder_state == "active":
    history_index += 3
order = orders[history_index]
assert sorted(order) == [1, 2, 3]
order_value = ",".join(map(str, order))
print("Recovery history seed 126, waiter submission order:", order, flush=True)
m1.succeed(
    "systemd-run --quiet --no-block --unit=database-recovery-client "
    "--property=StandardOutput=append:/var/lib/overalls-fleet/recovery-public.log "
    "--property=StandardError=null "
    "--setenv=PATH=/run/current-system/sw/bin "
    "--setenv=FLEET_RECOVERY_ORDER=" + order_value + " "
    "--property=UMask=0077 /run/current-system/sw/bin/database-recovery-client"
)
try:
    m1.wait_for_file("/var/lib/overalls-fleet/settings.json", timeout=30)
except Exception:
    print(m1.succeed("cat /var/lib/overalls-fleet/recovery-public.log"))
    raise
settings: object = json.loads(m1.succeed("cat /var/lib/overalls-fleet/settings.json"))
assert fields(settings) == {
    "client_connection_check_ms": expected_connection_check_ms,
    "tcp_user_timeout_ms": expected_tcp_user_timeout_ms,
    "healthy_query": True,
}
backend_ids: list[int] = []
for index in range(4):
    path = f"/var/lib/overalls-fleet/backend-{index}.json"
    m1.wait_for_file(path, timeout=15)
    parsed: object = json.loads(m1.succeed("cat " + path))
    pid = fields(parsed)["pid"]
    assert type(pid) is int and pid > 0
    backend_ids.append(pid)
assert len(set(backend_ids)) == 4
holder, *waiters = backend_ids
waiter_sql = ",".join(map(str, waiters))


def queued() -> bool:
    return (
        sql(
            "SELECT count(*) FROM pg_stat_activity WHERE pid IN ("
            + waiter_sql
            + ") AND state='active' AND wait_event_type='Lock' "
            "AND cardinality(pg_blocking_pids(pid))>0 "
            "AND pg_blocking_pids(pid) <@ ARRAY["
            + ",".join(map(str, backend_ids))
            + "]::integer[] "
            "AND clock_timestamp()-query_start >= interval '2 seconds'"
        )
        == "3"
    )


assert eventually(queued, 8), "Three native waiters did not reach the lock queue"
assert sql(f"SELECT state FROM pg_stat_activity WHERE pid={holder}") == expected_holder_state
all_ids = sql(
    "SELECT string_agg(pid::text,',') FROM pg_stat_activity "
    "WHERE application_name='marshall:recovery-client'"
)
all_pids = [int(value) for value in all_ids.split(",")]
assert set(backend_ids).issubset(all_pids) and len(all_pids) == 10
assert all(pid > 0 for pid in all_pids)
print("Verified holder, three lock waiters and ten release Repo connections", flush=True)
if fault_mode == "crash":
    m1.crash()
else:
    assert fault_mode in {"silent", "asymmetric"}
    # Freeze userspace to prevent retries while preserving live kernel sockets.
    # DROP never generates a reset. The server's own observation supplies the
    # exact fixture peer; it is validated before entering firewall syntax.
    address = ipaddress.ip_address(
        sql(f"SELECT host(client_addr) FROM pg_stat_activity WHERE pid={holder}")
    )
    assert isinstance(address, ipaddress.IPv4Address)
    m1.succeed("systemctl freeze database-recovery-client")
    rules = (
        "table inet recovery_loss { chain inbound { type filter hook input priority -100; "
        f"ip saddr {address} tcp dport 5432 counter drop; }}\n"
    )
    if fault_mode == "silent":
        rules += (
            "chain outbound { type filter hook output priority -100; "
            f"ip daddr {address} tcp sport 5432 counter drop; }}\n"
        )
    rules += "}"
    db.succeed("printf %s " + shlex.quote(rules) + " | nft -f -")
lost_at = time.monotonic()
holder_reclaimed = eventually(
    lambda: sql(f"SELECT count(*) FROM pg_stat_activity WHERE pid={holder}") == "0", 20
)
if not holder_reclaimed:
    # Failure diagnostics contain only fixture IDs and closed server state;
    # they cannot extend the deadline or expose statements or credentials.
    print(
        "Holder reclamation failure:",
        round(time.monotonic() - lost_at, 3),
        sql(
            "SELECT coalesce(json_agg(json_build_object('pid',pid,'state',state,"
            "'wait',wait_event,'blockers',pg_blocking_pids(pid))),'[]') "
            "FROM pg_stat_activity WHERE pid IN (" + all_ids + ")"
        ),
        flush=True,
    )
assert holder_reclaimed, "Abandoned holder exceeded its existing 20-second bound"


def reclaimed() -> bool:
    return sql("SELECT count(*) FROM pg_stat_activity WHERE pid IN (" + all_ids + ")") == "0"


passed = eventually(reclaimed, max(0.1, 35 - (time.monotonic() - lost_at)))
if not passed:
    print("Original 35-second connection reclamation bound failed", flush=True)
    # Failure-only observation cannot convert the original bound into a pass.
    deadline = lost_at + 75
    while time.monotonic() < deadline:
        print(
            "Orphan state sample:",
            round(time.monotonic() - lost_at, 3),
            sql(
                "SELECT coalesce(json_agg(json_build_object('pid',pid,'state',state,"
                "'wait',wait_event,'state_age',extract(epoch FROM clock_timestamp()-state_change),"
                "'query_age',extract(epoch FROM clock_timestamp()-query_start),"
                "'blockers',pg_blocking_pids(pid))),'[]') FROM pg_stat_activity WHERE pid IN ("
                + all_ids
                + ")"
            ),
            flush=True,
        )
        if reclaimed():
            break
        time.sleep(1)
assert passed, "Lost release Repo connections exceeded the existing 35-second bound"
print("All release Repo connections reclaimed:", round(time.monotonic() - lost_at, 3), flush=True)
if fault_mode != "crash":
    counters = drop_counters()
    direction = "outbound" if fault_mode == "silent" else "inbound"
    assert counters[direction] > 0, "Configured packet-loss direction was not exercised"
    print("Observed fixture DROP counters:", counters, flush=True)
assert sql("SELECT true FROM overalls_fleet_fixture FOR UPDATE") == "t"
