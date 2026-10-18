"""Exercise packaged Lilly network rules with a real disposable native guest."""

from __future__ import annotations

import argparse
import hashlib
import json
import shlex
import socket
import subprocess
import sys
import time
from dataclasses import dataclass
from pathlib import Path

import native_service_runner as runner
import native_services as services
from native_control import object_value

ROOT = Path("/run/native-isolation")
PEER = "native-isolation-peer"
PORT = 18080
PUBLIC = "8.8.8.8"
PROTECTED = "8.8.4.5"
SIBLING = "10.20.0.204"
FOREIGN = "10.20.0.205"
PRIVATE = "172.16.20.1"
FIXED_SERVICE = "169.254.254.1"
NETWORK = runner.Network("10.20.0.203", "10.20.0.1", "02:fc:0a:14:00:cb")
DESTINATIONS = (PUBLIC, PROTECTED, SIBLING, PRIVATE, FIXED_SERVICE, NETWORK.gateway)


@dataclass(frozen=True)
class Identity:
    """Only the exact source-generated synthetic network enters this test."""

    namespace: str
    tap: str
    guard: str
    ingress_mark: int


@dataclass
class Options(argparse.Namespace):
    serve: Path | None = None
    image: Path | None = None
    vmm: Path | None = None
    fixture: Path | None = None
    work: Path | None = None
    os: services.Os = "freebsd"


def identity(body: bytes) -> Identity:
    """@cc [owner:ghuntley,label:verification;security] native-policy-closed-identity
    External policy metadata MUST match the exact validated synthetic identity,
    including its derived namespace, TAP, MAC, source and ingress mark. Unknown
    fields or coercible scalar types MUST NOT enter host commands.
    """
    tag = hashlib.sha256(b"11111111-1111-4111-8111-111111111111").hexdigest()[:12]
    expected: dict[str, object] = {
        "namespace": f"lilly-{tag}",
        "tap": f"lv{tag}",
        "guard": "guard_11111111111141118111111111111111",
        "address": NETWORK.address,
        "gateway": NETWORK.gateway,
        "mac": NETWORK.mac,
        "ingress_mark": 0x41554449,
    }
    services.expect(services.decode_object(body), expected)
    return Identity(f"lilly-{tag}", f"lv{tag}", str(expected["guard"]), 0x41554449)


def counts(path: Path) -> dict[str, int]:
    """Narrow a sink's public connection counters without trusting JSON types."""
    value = services.decode_object(path.read_bytes())
    if value.keys() != set(DESTINATIONS):
        raise services.ProtocolError("invalid native isolation counters")
    result: dict[str, int] = {}
    for destination in DESTINATIONS:
        count = value[destination]
        if type(count) is not int or not 0 <= count <= 10_000:
            raise services.ProtocolError("invalid native isolation counters")
        result[destination] = count
    return result


def serve(path: Path) -> None:
    """Retain only bounded destination counters, without reading guest bytes."""
    hits = dict.fromkeys(DESTINATIONS, 0)
    path.parent.mkdir(parents=True, exist_ok=True)
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as listener:
        listener.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
        listener.bind(("0.0.0.0", PORT))
        listener.listen(4)
        path.write_text(json.dumps(hits), encoding="utf-8")
        while True:
            connection, _peer = listener.accept()
            with connection:
                address: object = connection.getsockname()
                if (
                    not isinstance(address, tuple)
                    or len(address) != 2
                    or not isinstance(address[0], str)
                    or address[0] not in hits
                ):
                    raise RuntimeError("unexpected native isolation destination")
                destination = address[0]
                hits[destination] += 1
                if hits[destination] > 10_000:
                    raise RuntimeError("native isolation sink exceeded its bound")
                temporary = path.with_suffix(".tmp")
                temporary.write_text(json.dumps(hits), encoding="utf-8")
                temporary.replace(path)


def observed(local: Path, peer: Path) -> dict[str, int]:
    return counts(peer) | {
        destination: count
        for destination, count in counts(local).items()
        if destination in (FIXED_SERVICE, NETWORK.gateway)
    }


def wait_connections(local: Path, peer: Path, expected: dict[str, int]) -> dict[str, int]:
    deadline = time.monotonic() + 2
    while True:
        result = observed(local, peer)
        if all(result[destination] >= minimum for destination, minimum in expected.items()):
            return result
        if time.monotonic() >= deadline:
            raise RuntimeError("native isolation positive control did not reach its listener")
        time.sleep(0.02)


def command(context: runner.BootContext, body: str, expected: bytes) -> None:
    result = runner.ssh(
        context.fixture,
        context.work / "known_hosts",
        body,
        network=context.network,
    )
    runner.success(result, expected)


def probe(context: runner.BootContext, destination: str, *, allowed: bool) -> None:
    if destination not in DESTINATIONS:
        raise ValueError("unreviewed native isolation target")
    status = "0" if allowed else "1"
    command(
        context,
        f"if {tcp_command(context.platform, destination)} >/dev/null 2>&1; "
        "then status=0; else status=1; fi; "
        f'test "$status" = {status} && printf native-network-checked',
        b"native-network-checked",
    )


def tcp_command(platform: runner.Platform, destination: str, source: str | None = None) -> str:
    if destination not in DESTINATIONS or source not in (None, FOREIGN):
        raise ValueError("unreviewed native TCP probe identity")
    if platform.name == "freebsd":
        bind = "" if source is None else f" -s {source}"
        return f"/usr/bin/nc -z -w 2{bind} {destination} {PORT}"
    # This source is independently formatted, linted and type-checked. The
    # official image pins Python 3.12; the probe uses its compatible socket API.
    script = Path(__file__).with_name("native_tcp_probe.py").read_text(encoding="utf-8")
    bind = "" if source is None else f" --source {source}"
    return f"/usr/bin/python3.12 -c {shlex.quote(script)} {destination}{bind}"


def foreign_source_commands(platform: runner.Platform) -> tuple[str, str]:
    """@cc [owner:ghuntley,label:verification;security] native-isolation-source-dialect
    The unassigned-source probe MUST use the reviewed interface and reversible
    address operation for the selected native OS. Unknown platforms MUST be
    rejected before any host or guest command is constructed.
    """
    if platform.name == "freebsd":
        return (
            f"/sbin/ifconfig vtnet0 inet {FOREIGN}/32 alias",
            f"/sbin/ifconfig vtnet0 inet {FOREIGN} -alias",
        )
    if platform.name == "illumos":
        return (
            f"/sbin/ifconfig vioif0 addif {FOREIGN}/32 up",
            f"/sbin/ifconfig vioif0 removeif {FOREIGN}",
        )
    raise ValueError("unreviewed native isolation platform")


def nft(*arguments: str) -> None:
    subprocess.run(["nft", *arguments], stdin=subprocess.DEVNULL, check=True, timeout=10)


def policy_counters() -> dict[str, list[int]]:
    """Retain only kernel packet counts from this fixture's reviewed policy."""
    result = subprocess.run(
        ["nft", "-j", "list", "table", "inet", "lilly_filter"],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        check=True,
        timeout=5,
    )
    if len(result.stdout) > 65_536:
        raise RuntimeError("native isolation counter inventory exceeded its bound")
    entries = services.decode_object(result.stdout).get("nftables")
    if not isinstance(entries, list) or len(entries) > 128:
        raise RuntimeError("invalid native isolation counter inventory")
    counters: dict[str, list[int]] = {"input": [], "output": [], "forward": []}
    for entry in entries:
        raw = object_value(entry).get("rule")
        if raw is None:
            continue
        rule = object_value(raw)
        chain = rule.get("chain")
        expressions = rule.get("expr")
        if not isinstance(chain, str) or chain not in counters:
            continue
        if not isinstance(expressions, list) or len(expressions) > 16:
            raise RuntimeError("invalid native isolation counter rule")
        for expression in expressions:
            raw_counter = object_value(expression).get("counter")
            if raw_counter is None:
                continue
            packets = object_value(raw_counter).get("packets")
            if type(packets) is not int or packets < 0:
                raise RuntimeError("invalid native isolation packet counter")
            counters[chain].append(packets)
    return counters


def guard_drops(guard: str) -> int:
    """Read the actual TAP guard's explicit drop counters, including ARP."""
    result = subprocess.run(
        ["nft", "-j", "list", "chain", "netdev", guard, "ingress"],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        check=True,
        timeout=5,
    )
    document = services.decode_object(result.stdout)
    objects = document.get("nftables")
    if not isinstance(objects, list) or len(objects) > 32:
        raise RuntimeError("invalid native isolation rule inventory")
    matches: list[int] = []
    for item in objects:
        rule = object_value(item).get("rule")
        if not isinstance(rule, dict):
            continue
        expressions = object_value(rule).get("expr")
        if not isinstance(expressions, list) or not expressions or len(expressions) > 8:
            continue
        if expressions[-1] != {"drop": None}:
            continue
        for expression in expressions:
            counters = object_value(expression).get("counter")
            if not isinstance(counters, dict):
                continue
            packets = object_value(counters).get("packets")
            if type(packets) is not int or packets < 0:
                raise RuntimeError("invalid native isolation drop counter")
            matches.append(packets)
    if len(matches) != 5:
        raise RuntimeError("missing native isolation TAP drop rules")
    return sum(matches)


def foreign_source(context: runner.BootContext, *, allowed: bool) -> None:
    """Attempt an unassigned source while retaining the real SSH identity."""
    add, remove = foreign_source_commands(context.platform)
    status = "0" if allowed else "1"
    cleanup = f"{remove} >/dev/null 2>&1"
    script = (
        f"set -eu; {add} >/dev/null; trap {shlex.quote(cleanup)} EXIT HUP INT TERM; "
        f"if {tcp_command(context.platform, PUBLIC, FOREIGN)} >/dev/null 2>&1; "
        "then status=0; else status=1; fi; "
        f'test "$status" = {status}; printf native-source-checked'
    )
    command(
        context,
        f"{context.platform.sudo} -n {context.platform.bash} -c {shlex.quote(script)}",
        b"native-source-checked",
    )


def ssh_mark_rules(network: Identity) -> str:
    """@cc [owner:ghuntley,label:verification;security] native-fixture-ssh-mark-scope
    Generated rules MUST mark only packets to NETWORK.address TCP port 22.
    Other guest destinations and protocols MUST NOT acquire the fixture mark.
    """
    return (
        "table inet native_fixture_mark {\n"
        "  chain output {\n"
        "    type route hook output priority mangle; policy accept;\n"
        f"    ip daddr {NETWORK.address} tcp dport 22 meta mark set {network.ingress_mark};\n"
        "  }\n"
        "}\n"
    )


def verify(context: runner.BootContext) -> None:
    """@cc [owner:ghuntley,label:verification;security] native-isolation-positive-controls
    A refused connection MUST be attempted against a listener proven reachable
    from this same native boot before policy installation. The test MUST retain
    a permitted public connection and private authority under the real policy,
    observe the source guard's kernel counter, and restore policy before reboot.
    This scope MUST NOT establish jail, physical host or multi-host isolation.
    """
    if context.network != NETWORK:
        raise RuntimeError("native isolation used an unexpected network identity")
    network = identity((ROOT / "identity.json").read_bytes())
    directory = context.work / f"isolation-{context.boot.boot_id}"
    directory.mkdir(exist_ok=False)
    local_counts = directory / "local.json"
    peer_counts = directory / "peer.json"
    processes: list[subprocess.Popen[bytes]] = []
    installed = False
    marked = False
    phase = "listener-startup"
    try:
        for prefix, path in (([], local_counts), (["ip", "netns", "exec", PEER], peer_counts)):
            processes.append(
                subprocess.Popen(
                    [*prefix, sys.executable, __file__, "--serve", str(path)],
                    stdin=subprocess.DEVNULL,
                    stdout=subprocess.DEVNULL,
                    stderr=subprocess.DEVNULL,
                )
            )
        deadline = time.monotonic() + 5
        while not local_counts.exists() or not peer_counts.exists():
            if any(process.poll() is not None for process in processes):
                raise RuntimeError("native isolation sink exited")
            if time.monotonic() >= deadline:
                raise RuntimeError("native isolation sink did not start")
            time.sleep(0.05)
        phase = "positive-controls"
        for destination in DESTINATIONS:
            probe(context, destination, allowed=True)
        phase = "foreign-source-positive-control"
        foreign_source(context, allowed=True)
        baseline = dict.fromkeys(DESTINATIONS, 1)
        baseline[PUBLIC] = 2
        wait_connections(local_counts, peer_counts, baseline)
        # This only marks this root-owned fixture's exact SSH destination, as
        # Lilly.Network.Ingress does through SO_MARK. Production policy remains
        # unchanged and still decides whether the marked flow is admitted.
        mark = directory / "ssh-mark.nft"
        mark.write_text(ssh_mark_rules(network), encoding="utf-8")
        nft("-f", str(mark))
        marked = True
        nft("-f", str(ROOT / "policy.nft"))
        installed = True
        phase = "public-under-policy"
        before = observed(local_counts, peer_counts)
        probe(context, PUBLIC, allowed=True)
        phase = "refusals-under-policy"
        for destination in DESTINATIONS:
            if destination != PUBLIC:
                probe(context, destination, allowed=False)
        drops = guard_drops(network.guard)
        phase = "foreign-source-under-policy"
        foreign_source(context, allowed=False)
        if guard_drops(network.guard) <= drops:
            raise RuntimeError("unassigned native source did not reach the source guard")
        phase = "public-after-foreign-source"
        probe(context, PUBLIC, allowed=True)
        after = wait_connections(local_counts, peer_counts, {PUBLIC: before[PUBLIC] + 2})
        if after[PUBLIC] != before[PUBLIC] + 2 or any(
            after[destination] != before[destination]
            for destination in DESTINATIONS
            if destination != PUBLIC
        ):
            raise RuntimeError("native isolation sink observed an invalid connection")
        runner.alive(context.process)
        if any(process.poll() is not None for process in processes):
            raise RuntimeError("native isolation sink lost its positive control")
        (directory / "receipt.json").write_text(
            json.dumps(
                {
                    "version": 1,
                    "os": context.platform.name,
                    "boot_id": context.boot.boot_id,
                    "policy_sha256": runner.digest(ROOT / "policy.nft"),
                    "native_admission": False,
                    "checks": [
                        "all-sinks-reachable-before-policy",
                        "public-tcp-still-allowed",
                        "sibling-private-protected-host-and-unregistered-service-refused",
                        "unassigned-source-refused-by-kernel-counter",
                        "allowed-source-recovers",
                    ],
                    "scope": "native IPv4 over Lilly router and TAP source guard; no jail or physical isolation",
                },
                sort_keys=True,
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
    except (OSError, RuntimeError, subprocess.SubprocessError):
        # These closed labels identify the failed boundary without exposing
        # SSH commands, credentials, user bytes or private callback payloads.
        print(f"native isolation failed at {phase}", flush=True)
        if installed:
            print(f"native isolation packet counters: {json.dumps(policy_counters())}", flush=True)
        raise
    finally:
        tables = []
        if installed:
            tables.extend(
                (
                    ("netdev", network.guard),
                    ("inet", "lilly_filter"),
                    ("ip", "lilly_nat"),
                )
            )
        if marked:
            tables.append(("inet", "native_fixture_mark"))
        try:
            for family, table in tables:
                nft("delete", "table", family, table)
        finally:
            for process in processes:
                process.terminate()
                try:
                    process.wait(timeout=5)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=5)


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--serve", type=Path)
    parser.add_argument("--image", type=Path)
    parser.add_argument("--vmm", type=Path)
    parser.add_argument("--fixture", type=Path)
    parser.add_argument("--work", type=Path)
    parser.add_argument("--os", choices=("freebsd", "illumos"), default="freebsd")
    arguments = parser.parse_args(namespace=Options())
    if arguments.serve is not None:
        serve(arguments.serve)
        return
    image, vmm, fixture, work = arguments.image, arguments.vmm, arguments.fixture, arguments.work
    if image is None or vmm is None or fixture is None or work is None:
        parser.error("image, VMM, fixture and work are required")
    network = identity((ROOT / "identity.json").read_bytes())
    runner.run(
        image,
        vmm,
        fixture,
        network.tap,
        work,
        network=NETWORK,
        os_name=arguments.os,
        verify_boot=verify,
    )


if __name__ == "__main__":
    main()
