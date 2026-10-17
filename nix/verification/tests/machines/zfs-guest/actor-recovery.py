"""Real completed Firecracker effects recovered across actor crash histories."""

from hypothesis import example, given, settings
from hypothesis import strategies as st

storage.start()
storage.wait_for_unit("multi-user.target")
storage.succeed(
    "test -c /dev/kvm", "systemctl is-active lilly.slice", "systemctl is-active lilly-hostd.service"
)
storage.succeed(
    "zpool create -f -O compression=lz4 -O mountpoint=/tank tank mirror /dev/vdb /dev/vdc"
)
(
    base_disk_bytes,
    grown_disk_bytes,
    pool_quota_bytes,
    base_memory_bytes,
    grown_memory_bytes,
) = create_guest_pool()

next_number: int = 101


@settings(max_examples=2, deadline=None, derandomize=True)
@example(generation=1, replays=1)
@example(generation=9_223_372_036_854_775_805, replays=3)
@given(
    generation=st.sampled_from([1, 2, 9_223_372_036_854_775_805]),
    replays=st.sampled_from([1, 2, 3]),
)
def completed_effect_recovery(generation: int, replays: int) -> None:
    """@cc [owner:ghuntley,label:verification;recovery] generated-native-actor-recovery
    Each generated history MUST boot through the real executor and recover the
    actor after completed effect/before record. The same native process MUST
    remain usable after the worker exits; cleanup MUST remove its real dataset.
    """
    global next_number
    number = next_number
    next_number += 1
    placement = "dddddddd-dddd-4ddd-8ddd-" + str(number).rjust(12, "0")
    storage.succeed(f"zfs-guest actor-recovery {generation} {number} {replays}")
    before = storage.succeed(f"zfs-guest-processes {placement}")
    storage.succeed(f"zfs-guest write {generation} {number}")
    storage.succeed(f"zfs-guest read {generation} {number}")
    assert storage.succeed(f"zfs-guest-processes {placement}") == before
    storage.succeed(f"zfs-guest delete {generation + 1} {number}")
    storage.fail(f"zfs list tank/lilly/vm-{placement}")
    storage.fail(f"test -e /pool/vms/{placement}/rootfs.ext4")


with subtest("completed native launch survives actor death before durable outcome recording"):
    completed_effect_recovery()


@settings(max_examples=1, deadline=None, derandomize=True)
@example(generation=1, reopens=1)
@example(generation=9_223_372_036_854_775_805, reopens=3)
@given(
    generation=st.sampled_from([1, 2, 9_223_372_036_854_775_805]),
    reopens=st.sampled_from([1, 2, 3]),
)
def completed_effect_beam_recovery(generation: int, reopens: int) -> None:
    """@cc [owner:ghuntley,label:verification;recovery] generated-native-beam-recovery
    Abrupt exit of the whole source-built worker BEAM after completed effect and
    before outcome recording MUST retain the native VMM. Each fresh recovery BEAM
    MUST reopen durable intent/journal locks and replay one stable outcome while
    preserving VMM identity and launch marker. Cleanup MUST remove the dataset.
    """
    global next_number
    number = next_number
    next_number += 1
    placement = "dddddddd-dddd-4ddd-8ddd-" + str(number).rjust(12, "0")
    status, _ = storage.execute(f"zfs-guest beam-crash {generation} {number} 1")
    assert status == 137, "completed-effect worker must exit at the abrupt BEAM barrier"
    before = storage.succeed(f"zfs-guest-processes {placement}")
    for _ in range(reopens):
        storage.succeed(f"zfs-guest beam-recover {generation} {number} 1")
        assert storage.succeed(f"zfs-guest-processes {placement}") == before
        storage.succeed(f"zfs-guest write {generation} {number}")
        storage.succeed(f"zfs-guest read {generation} {number}")
        assert storage.succeed(f"zfs-guest-processes {placement}") == before
    storage.succeed(f"zfs-guest delete {generation + 1} {number}")
    storage.fail(f"zfs list tank/lilly/vm-{placement}")
    storage.fail(f"test -e /pool/vms/{placement}/rootfs.ext4")


with subtest("completed native launch survives abrupt worker BEAM loss and fresh Store reopen"):
    completed_effect_beam_recovery()
