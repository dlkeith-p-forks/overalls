"""Real completed Firecracker effects recovered across Hegel actor histories.

The registered properties preserve the evidence labels ``completed native launch
survives actor death before durable outcome recording`` and ``completed native
launch survives abrupt worker BEAM loss and fresh Store reopen``.
# completed native launch survives actor death before durable outcome recording
# completed native launch survives abrupt worker BEAM loss and fresh Store reopen
"""

from hegel import TestCase, given, sampled_from

storage.start()
storage.wait_for_unit("multi-user.target")
storage.succeed(
    "test -c /dev/kvm", "systemctl is-active lilly.slice", "systemctl is-active lilly-hostd.service"
)
storage.succeed(
    "zpool create -f -O compression=lz4 -O mountpoint=/tank tank mirror /dev/vdb /dev/vdc"
)
create_guest_pool()

next_number: int = 101


def _placement(number: int) -> str:
    return "dddddddd-dddd-4ddd-8ddd-" + str(number).rjust(12, "0")


def _cleanup(generation: int, number: int) -> None:
    """Return one generated case to the empty pool baseline after any failure."""
    # The fixture command fences duplicate deletes; ignore a missing placement
    # when setup failed before the native dataset was created.
    storage.execute(f"zfs-guest delete {generation + 1} {number}")
    storage.execute(f"zfs destroy -r tank/lilly/vm-{_placement(number)}")
    storage.execute(f"rm -rf /pool/vms/{_placement(number)}")


@given(generation=sampled_from([1, 2, 9_223_372_036_854_775_805]), replays=sampled_from([1, 2, 3]))
def completed_effect_recovery(tc: TestCase, generation: int, replays: int) -> None:
    """@cc [owner:ghuntley,label:verification;recovery] generated-native-actor-recovery
    Each generated history MUST boot through the real executor and recover the
    actor after completed effect/before record. The same native process MUST
    remain usable after the worker exits; cleanup MUST remove its real dataset.
    """
    global next_number
    number = next_number
    next_number += 1
    placement = _placement(number)
    try:
        storage.succeed(f"zfs-guest actor-recovery {generation} {number} {replays}")
        before = storage.succeed(f"zfs-guest-processes {placement}")
        storage.succeed(f"zfs-guest write {generation} {number}")
        storage.succeed(f"zfs-guest read {generation} {number}")
        assert storage.succeed(f"zfs-guest-processes {placement}") == before
        storage.succeed(f"zfs-guest delete {generation + 1} {number}")
        storage.fail(f"zfs list tank/lilly/vm-{placement}")
        storage.fail(f"test -e /pool/vms/{placement}/rootfs.ext4")
    finally:
        _cleanup(generation, number)


@given(generation=sampled_from([1, 2, 9_223_372_036_854_775_805]), reopens=sampled_from([1, 2, 3]))
def completed_effect_beam_recovery(tc: TestCase, generation: int, reopens: int) -> None:
    """@cc [owner:ghuntley,label:verification;recovery] generated-native-beam-recovery
    Abrupt exit of the whole source-built worker BEAM after completed effect and
    before outcome recording MUST retain the native VMM. Each fresh recovery BEAM
    MUST reopen durable intent/journal locks and replay one stable outcome while
    preserving VMM identity and launch marker. Cleanup MUST remove the dataset.
    """
    global next_number
    number = next_number
    next_number += 1
    placement = _placement(number)
    try:
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
    finally:
        _cleanup(generation, number)
