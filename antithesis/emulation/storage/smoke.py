"""Bounded first TCG boot, native cache interception and retained import smoke."""

import argparse
import fcntl
import json
import secrets
import time
from pathlib import Path
from typing import TypedDict

from runner import Config, guest_request, qmp_reset, start


class Reply(TypedDict):
    version: int
    id: str
    status: str
    observation: object


def request(
    config: Config,
    identifier: str,
    action: str,
    target: str | None = None,
    value: str | None = None,
) -> Reply:
    raw = guest_request(
        config,
        {"version": 1, "id": identifier, "action": action, "target": target, "value": value},
    )
    if raw.get("status") != "ok" or not isinstance(raw.get("observation"), dict):
        raise ValueError("router guest evidence unavailable")
    return Reply(version=1, id=identifier, status="ok", observation=raw["observation"])


def observation(reply: Reply) -> dict[str, object]:
    value = reply["observation"]
    if not isinstance(value, dict):
        raise ValueError("invalid router observation")
    return value


def wait_observe(config: Config, previous_boot: str | None = None) -> dict[str, object]:
    deadline = time.monotonic() + 900
    while time.monotonic() < deadline:
        try:
            observed = observation(request(config, "0000000000000001", "observe"))
            boot = observed.get("boot_id")
            if isinstance(boot, str) and boot != previous_boot:
                return observed
        except (OSError, ValueError, TimeoutError):
            pass
        time.sleep(2)
    raise TimeoutError("TCG router readiness deadline exceeded")


def wait_cache(config: Config, minimum: int) -> dict[str, object]:
    deadline = time.monotonic() + 60
    while time.monotonic() < deadline:
        try:
            observed = observation(request(config, "0000000000000009", "observe"))
            objects = observed.get("cache_objects")
            if isinstance(objects, list) and len(objects) >= minimum:
                return observed
        except (OSError, ValueError, TimeoutError):
            pass
        time.sleep(1)
    raise TimeoutError("Brady cache publication deadline exceeded")


def wait_probe(config: Config, identifier: str, route: str, key: str) -> dict[str, object]:
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        try:
            return observation(request(config, identifier, "probe", route, key))
        except (OSError, ValueError, TimeoutError):
            time.sleep(2)
    raise TimeoutError("Brady interception readiness deadline exceeded")


def integer(record: dict[str, object], key: str) -> int:
    value = record.get(key)
    if type(value) is not int:
        raise ValueError(f"missing numeric {key}")
    return value


def count(record: dict[str, object], key: str) -> int:
    if key not in record:
        return 0
    return integer(record, key)


def progress(stage: str) -> None:
    print(json.dumps({"stage": stage}, sort_keys=True), flush=True)


def main() -> None:
    """@cc [owner:ghuntley,label:verification] first-router-smoke-scope
    This is a real TCG kernel, ZFS and Brady smoke. It records post-reset
    evidence and MUST NOT be reported as KVM, Firecracker or physical power loss.
    """
    parser = argparse.ArgumentParser()
    parser.add_argument("--config", type=Path, required=True)
    arguments = parser.parse_args()
    config = Config.read(arguments.config)
    config.state_dir.mkdir(mode=0o700, parents=True, exist_ok=True)
    with (config.state_dir / "owner.lock").open("a+b") as owner:
        fcntl.flock(owner, fcntl.LOCK_EX)
        started = start(config)
        progress("qemu-started")
        before = wait_observe(config)
        progress("first-observation")
        if (
            integer(before, "cache_quota") != 67108864
            or integer(before, "cache_refquota") != 67108864
        ):
            raise ValueError("production prepare/fixture quota ordering failed")
        nft_before = before.get("nft")
        origin_before = before.get("origin_effects")
        objects_before = before.get("cache_objects")
        if (
            not isinstance(nft_before, dict)
            or not isinstance(origin_before, dict)
            or not isinstance(objects_before, list)
        ):
            raise ValueError("network oracle unavailable")
        public_key = secrets.token_hex(8)
        probe = wait_probe(config, "0000000000000002", "public_http", public_key)
        progress("http-intercepted")
        if (
            probe.get("bytes") != 22
            or probe.get("sha256")
            != "4e9d451a3fcee7112d27aa982c0fe155d5185888769148ddda3fe7c8af1aae50"
        ):
            raise ValueError("intercepted origin bytes changed")
        tls_probe = wait_probe(config, "0000000000000004", "public_https", public_key)
        progress("https-intercepted")
        if tls_probe.get("bytes") != probe.get("bytes") or tls_probe.get("sha256") != probe.get(
            "sha256"
        ):
            raise ValueError("intercepted TLS origin bytes changed")
        after_probe = wait_cache(config, len(objects_before) + 2)
        progress("cache-published")
        nft_after = after_probe.get("nft")
        origin_after = after_probe.get("origin_effects")
        if not isinstance(nft_after, dict) or not isinstance(origin_after, dict):
            raise ValueError("post-request oracle unavailable")
        if integer(nft_after, "packets") <= integer(nft_before, "packets"):
            raise ValueError("nft interception counter did not move")
        if count(origin_after, "http:public") <= count(origin_before, "http:public"):
            raise ValueError("independent origin effect not recorded")
        if count(origin_after, "https:public") <= count(origin_before, "https:public"):
            raise ValueError("independent TLS origin effect not recorded")
        request(config, "0000000000000005", "service_stop", "origin")
        try:
            request(config, "0000000000000006", "probe", "public_http", public_key)
            request(config, "0000000000000007", "probe", "public_https", public_key)
            cached = wait_observe(config)
            progress("origin-off-cache-reused")
            cached_effects = cached.get("origin_effects")
            if cached_effects != origin_after:
                raise ValueError("cache replay contacted the stopped origin")
        finally:
            request(config, "0000000000000008", "service_start", "origin")
        marker = observation(request(config, "0000000000000003", "write_marker"))
        progress("marker-fsynced")
        if marker.get("id") != "0000000000000003" or not isinstance(marker.get("sha256"), str):
            raise ValueError("fsynced marker acknowledgment missing")
        qmp_reset(config)
        progress("qmp-reset-acknowledged")
        retained = wait_observe(config, previous_boot=str(before["boot_id"]))
        progress("retained-observation")
        if retained.get("pool_guid") != before.get("pool_guid") or retained.get(
            "parent_guid"
        ) != before.get("parent_guid"):
            raise ValueError("retained ZFS identity changed")
        markers = retained.get("markers")
        if not isinstance(markers, list) or marker not in markers:
            raise ValueError("fsynced marker missing after QMP reset")
        if integer(retained, "cache_quota") != 67108864:
            raise ValueError("fixture quota missing after re-preparation")
    print(
        json.dumps(
            {
                "scope": "tcg-linux-zfs-brady",
                "qemu_pid": started["pid"],
                "before_boot": before["boot_id"],
                "after_boot": retained["boot_id"],
                "pool_guid": retained["pool_guid"],
                "parent_guid": retained["parent_guid"],
                "marker_sha256": marker["sha256"],
                "interception_packets": nft_after["packets"],
                "origin_http_public": origin_after["http:public"],
            },
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
