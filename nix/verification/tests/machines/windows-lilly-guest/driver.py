import json
import re

# @cc [owner:ghuntley,label:verification;security] windows-lilly-guest-host-side-evidence
# Guest evidence MUST come from the host side without any login: the bootstrap
# log the guest publishes on its EFI system partition is read from the live
# disk with mtools, the SAC prompt from the read-only boot log, and
# reachability of the delivered /32 (ICMP echo and the guest's TCP port 22)
# from Lilly's network namespace. Lilly's host policy drops every host-to-guest
# and guest-to-host packet of a Customer guest that carries no SSH or editor
# ingress mark, so the probe inserts a test-only accept for exactly this /32 in
# the `inet lilly_filter` input and output chains; the per-tap guard table is
# never touched and its counters are recorded as the packet-level proof that
# the guest sends from its assigned MAC and address. The Inception refusal is
# asserted before any dataset exists. Windows under nested KVM is slow, so the
# waits are generous.

storage.start()
storage.wait_for_unit("multi-user.target")
storage.succeed("test -c /dev/kvm", "systemctl is-active lilly.slice")
storage.succeed(
    "zpool create -f -O compression=lz4 -O mountpoint=/tank tank mirror /dev/vdb /dev/vdc"
)
storage.succeed("zfs create -o mountpoint=/pool tank/lilly")
vm = "dddddddd-dddd-4ddd-8ddd-000000000201"
child = f"tank/lilly/vm-{vm}"
disk = f"/pool/vms/{vm}/rootfs.ext4"


def esp_offset() -> int:
    table = json.loads(storage.succeed(f"sfdisk --json {disk}"))
    first = table["partitiontable"]["partitions"][0]
    return int(first["start"]) * 512


def esp_file(offset: int, name: str) -> str:
    # Read-only; the guest unmounts the ESP after publishing, so the directory
    # is consistent whenever the file is present.
    return storage.succeed(
        f"MTOOLS_SKIP_CHECK=1 mcopy -n -i {disk}@@{offset} ::/overalls/logs/{name} - 2>/dev/null || true"
    )


def allow_probe(namespace: str, address: str) -> None:
    # Test-only allowance in Lilly's host policy for this one /32; re-applied
    # after every launch because Network.attach re-renders the table.
    for chain, match in (
        ("output", f'oifname "lv*" ip daddr {address}'),
        ("input", f'iifname "lv*" ip saddr {address}'),
    ):
        storage.succeed(
            f"ip netns exec {namespace} nft insert rule inet lilly_filter {chain} {match} meta l4proto {{ icmp, tcp }} counter accept"
        )


def guard_counters(namespace: str, guard: str) -> str:
    return storage.succeed(f"ip netns exec {namespace} nft list table netdev {guard}")


def wait_bootstrap(offset: int, timeout: int) -> str:
    storage.wait_until_succeeds(
        f"MTOOLS_SKIP_CHECK=1 mcopy -n -i {disk}@@{offset} ::/overalls/logs/bootstrap-latest.log - 2>/dev/null | grep -q 'bootstrap complete'",
        timeout=timeout,
    )
    published = esp_file(offset, "bootstrap-latest.log")
    assert "FAIL" not in published, published
    assert "network applied" in published, published
    return published


with subtest("a firmware image refuses the Inception profile before any host effect"):
    storage.succeed("windows-lilly reject-inception 1", timeout=1800)

with subtest("Lilly places the firmware image and records the guest branch"):
    facts = json.loads(storage.succeed("windows-lilly start 1", timeout=3600).splitlines()[-1])
    assert facts["placement"] == vm
    expected_agents = (
        "windows-editor-v1" if editor_candidate else "windows-v1" if agents else "none"
    )
    assert facts["agents"] == expected_agents, facts
    if agents:
        assert facts["boot_id"] is not None, facts
    else:
        assert facts["boot_id"] is None, facts
    assert sorted(storage.succeed(f"ls -A /pool/vms/{vm}").split()) == [
        "boot-bundle.json",
        "firmware",
        "rootfs.ext4",
    ]
    # The 64 GiB sparse image (about 22 GB of data with the winget toolset,
    # ADR-0173) must not materialize as 64 GiB of pool usage.
    used = int(storage.succeed(f"zfs get -Hpo value used {child}").strip())
    assert used < 28 * 1024**3, used
    namespace, address, guard = facts["namespace"], facts["address"], facts["guard"]
    storage.succeed(f"ip netns exec {namespace} ip link show {facts['tap']}")
    storage.succeed(f"ip netns exec {namespace} nft list table netdev {guard}")

with subtest("the guest boots to the SAC prompt and configures its /32 from MMDS"):
    storage.wait_until_succeeds(f"grep -a -q 'SAC>' {facts['boot_log']}", timeout=2400)
    storage.copy_from_vm(facts["boot_log"], "first-boot")
    offset = esp_offset()
    bootstrap_log = wait_bootstrap(offset, 2400)
    print("bootstrap log:\n" + bootstrap_log)
    state = esp_file(offset, "network-state.json")
    assert f'"{address}"' in state, state
    assert "boot_challenge" in state
    if agents:
        # The daemons publish their closed-line logs beside the bootstrap log.
        readiness_log = esp_file(offset, "readinessd.log")
        trust_log = esp_file(offset, "trustd.log")
        storage.wait_until_succeeds(
            f"MTOOLS_SKIP_CHECK=1 mcopy -n -i {disk}@@{offset} ::/overalls/logs/agentd.log - 2>/dev/null | grep -q 'agentd start'",
            timeout=600,
        )
        agentd_log = esp_file(offset, "agentd.log")
        print("readinessd log:\n" + readiness_log)
        print("trustd log:\n" + trust_log)
        print("agentd log:\n" + agentd_log)
        assert "ready_answered" in readiness_log, readiness_log
        assert "receipt_sent" in trust_log, trust_log
        # The real Windows executor task starts in the guest's normal boot
        # path. This closed startup line proves the image launches agentd;
        # this Lilly-only fixture intentionally does not claim a control-plane
        # registration, context turn or provider exchange.
        assert "agentd start" in agentd_log, agentd_log

with subtest(
    "the host reaches the guest through a test-only policy allowance; the tap guard is intact"
):
    allow_probe(namespace, address)
    storage.wait_until_succeeds(f"ip netns exec {namespace} ping -c 1 -W 2 {address}", timeout=600)
    storage.succeed(f"ip netns exec {namespace} ping -c 3 -W 2 {address}")
    if agents:
        # windows-v1: sshd starts only after the roster agent applies a roster
        # from Marshall (ADR-0171), and this fixture has none, so port 22 stays
        # closed while the guest answers on its /32.
        storage.fail(f"ip netns exec {namespace} nc -z -w 5 {address} 22")
    else:
        storage.wait_until_succeeds(
            f"ip netns exec {namespace} nc -z -w 2 {address} 22", timeout=600
        )
    counters = guard_counters(namespace, guard)
    print("tap guard after probe:\n" + counters)
    # The guest's frames passed the guard's own source check: the IPv4 accept
    # rule for its assigned address counted packets.
    accepted = re.search(r"ip saddr [^\n]*counter packets (\d+) [^\n]*accept", counters)
    assert accepted is not None and int(accepted.group(1)) > 0, counters
    # Every probe invocation digest-verifies the full 64 GiB shared-store
    # image before its lifecycle action; retain the refusal probe's finite
    # image-verification budget for observation and cleanup as well.
    storage.succeed("windows-lilly observe 1", timeout=1800)

with subtest("stop, restart from the portable bundle without the image, and delete"):
    storage.succeed("windows-lilly stop 2", timeout=1800)
    restarted = json.loads(
        storage.succeed("windows-lilly restart 3", timeout=3600).splitlines()[-1]
    )
    assert restarted["agents"] == expected_agents, restarted
    if agents:
        # A new physical boot earns a new guest boot identity.
        assert restarted["boot_id"] is not None and restarted["boot_id"] != facts["boot_id"], (
            restarted
        )
    storage.wait_until_succeeds(f"grep -a -q 'SAC>' {facts['boot_log']}", timeout=2400)
    allow_probe(namespace, address)
    storage.wait_until_succeeds(f"ip netns exec {namespace} ping -c 1 -W 2 {address}", timeout=2400)
    storage.copy_from_vm(facts["boot_log"], "second-boot")
    storage.succeed("windows-lilly stop 4", timeout=1800)
    storage.succeed("windows-lilly delete 5", timeout=1800)
    storage.fail(f"zfs list {child}")
