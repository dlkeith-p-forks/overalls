"""Real template publication, independent disks, retirement and refusal boundaries."""

import shlex

storage.start()
storage.wait_for_unit("multi-user.target")
storage.succeed("zpool create -f -O compression=lz4 -O mountpoint=none tank /dev/vdb")
storage.succeed("zfs create -o mountpoint=/pool tank/lilly", "chmod 700 /pool")
storage.succeed(
    "mkdir -p /pool/.lilly-templates/records/eeeeeeee-eeee-4eee-8eee-000000000000",
    "chmod 700 /pool/.lilly-templates /pool/.lilly-templates/records "
    "/pool/.lilly-templates/records/eeeeeeee-eeee-4eee-8eee-000000000000",
)

with subtest("staged bytes are sealed and reusable after process restart"):
    storage.succeed("image-template ensure", "image-template warm", "image-template audit")
    storage.succeed("test $(zfs list -H -r -o name tank/lilly | wc -l) -eq 2")
    storage.succeed("image-template copy", "image-template ready", "image-template audit")

with subtest("sealed templates refuse writes and VM disks remain independent"):
    template = storage.succeed("zfs list -H -r -o name tank/lilly | grep /template-").strip()
    path = storage.succeed(f"zfs get -H -o value mountpoint {template}").strip()
    storage.fail(f"touch {path}/unexpected")
    storage.succeed(
        "printf independent | dd of=/pool/vms/dddddddd-dddd-4ddd-8ddd-000000000001/rootfs.ext4 conv=notrunc status=none"
    )
    storage.succeed("image-template warm", "image-template ready")

with subtest("unused LRU retirement leaves portable VM disks and boot artifacts"):
    storage.succeed("image-template ensure 2", "image-template audit")
    storage.fail(f"zfs list {template}")
    storage.succeed("image-template ready 1")
    storage.succeed(
        "test $(head -c 11 /pool/vms/dddddddd-dddd-4ddd-8ddd-000000000001/rootfs.ext4) = independent"
    )
    storage.succeed("image-template uncached 2")

with subtest("active native readers exclude budget retirement"):
    storage.succeed("systemd-run --unit=template-reader --collect image-template lease 2")
    storage.wait_until_succeeds("test -f /run/template-reader-ready")
    storage.succeed("image-template expect-budget-refusal 3")
    storage.succeed("systemctl stop template-reader.service")
    storage.succeed("image-template warm 2")

with subtest("quarantined incarnations retire before a fully verified replacement"):
    template = storage.succeed("zfs list -H -r -o name tank/lilly | grep /template-").strip()
    storage.succeed(f"zfs set readonly=off {template}")
    storage.succeed("image-template audit-refuse 2", "image-template refuse 2")
    storage.succeed(f"zfs set readonly=on {template}")
    storage.succeed("image-template warm 2", "image-template audit")
    storage.fail(f"zfs list {template}")
    storage.succeed("image-template ensure 3", "image-template warm 3")

with subtest("foreign native nonce is refused without deleting the template"):
    template = storage.succeed("zfs list -H -r -o name tank/lilly | grep /template-").strip()
    nonce = storage.succeed(f"zfs get -H -o value lilly:nonce {template}").strip()
    storage.succeed(f"zfs set lilly:nonce=foreign {template}")
    storage.succeed("image-template refuse 3", "image-template audit-refuse 3")
    storage.succeed("image-template refuse 3")
    storage.succeed(f"zfs list {template}")
    storage.succeed(f"zfs set lilly:nonce={nonce} {template}")
    storage.succeed("image-template warm 3")
    storage.fail(f"zfs list {template}")
    storage.succeed("image-template ensure 4", "image-template warm 4")

with subtest("same-size modification and resealing cannot bypass exact file identities"):
    template = storage.succeed("zfs list -H -r -o name tank/lilly | grep /template-").strip()
    path = storage.succeed(f"zfs get -H -o value mountpoint {template}").strip()
    storage.succeed(f"zfs set readonly=off {template}")
    storage.succeed(
        f"chmod 0644 {path}/kernel; printf x | dd of={path}/kernel conv=notrunc status=none; chmod 0444 {path}/kernel"
    )
    storage.succeed(f"zfs set readonly=on {template}")
    storage.succeed("image-template refuse 4")

# @cc [owner:ghuntley,label:verification;recovery] template-native-interrupted-effects
# Kill the real builder after each selected native effect but before its
# confirmation. A fresh process MUST resume from durable intent and revalidate
# ownership; the fault injector MUST NOT manufacture successful journal states.
storage.succeed(
    "mkdir -p /run/template-fault/bin",
    "ln -s /etc/template-zfs-fault /run/template-fault/bin/zfs",
    "ln -s /etc/template-copy-fault /run/template-fault/bin/lilly-image-copy",
)
for number, operation in [(5, "create"), (6, "copy"), (7, "set"), (8, "destroy")]:
    with subtest(f"recovery after interrupted native {operation}"):
        storage.succeed("rm -f /run/template-effect-committed")
        storage.succeed(
            f"systemd-run --unit=template-crash-{number} --collect "
            f"--setenv=TEMPLATE_PAUSE={operation} image-template ensure {number}"
        )
        storage.wait_until_succeeds("test -f /run/template-effect-committed")
        storage.succeed(f"systemctl kill --signal=KILL template-crash-{number}.service")
        storage.wait_until_fails(f"systemctl is-active template-crash-{number}.service")
        storage.succeed(
            f"image-template ensure {number}",
            f"image-template warm {number}",
            "image-template audit",
        )

# A template create that completed natively but lost its mount before the
# builder died (production, 2026-10-10: zfs create cut off at the short
# utility default) leaves an owned, unmounted template that accounting
# refuses; the next build mounts it and finishes.
with subtest("recovery after a template create left the dataset unmounted"):
    storage.succeed("rm -f /run/template-effect-committed")
    storage.succeed(
        "systemd-run --unit=template-crash-11 --collect "
        "--setenv=TEMPLATE_CREATE_UNMOUNTED=create image-template ensure 11"
    )
    storage.wait_until_succeeds("test -f /run/template-effect-committed")
    storage.succeed("systemctl kill --signal=KILL template-crash-11.service")
    storage.wait_until_fails("systemctl is-active template-crash-11.service")
    storage.succeed(
        'test "$(zfs list -H -o mounted -r tank/lilly | grep -c no)" -ge 1',
        "image-template audit-refuse",
    )
    storage.succeed("image-template ensure 11", "image-template warm 11", "image-template audit")

# A build interrupted for an image that is then no longer configured would
# otherwise stay unmounted forever and withhold the pool (production,
# 2026-10-10). The startup sweep mounts and retires it.
with subtest("unconfigured interrupted templates are swept"):
    # A sealed, read-only template of an image no longer configured retires.
    storage.succeed("image-template ensure 8")
    sealed = storage.succeed(
        "zfs list -H -o name,readonly -r tank/lilly | grep template- | grep -c on"
    ).strip()
    assert int(sealed) >= 1, sealed
    swept = storage.succeed("image-template retire-unconfigured 11")
    assert int(swept.split("retired=")[1].split()[0]) >= 1, swept
    storage.fail("zfs list -H -o name,readonly -r tank/lilly | grep template- | grep -q on")
    # A build interrupted after create but before its mount retires too.
    storage.succeed("rm -f /run/template-effect-committed")
    storage.succeed(
        "systemd-run --unit=template-crash-12 --collect "
        "--setenv=TEMPLATE_CREATE_UNMOUNTED=create image-template ensure 12"
    )
    storage.wait_until_succeeds("test -f /run/template-effect-committed")
    storage.succeed("systemctl kill --signal=KILL template-crash-12.service")
    storage.wait_until_fails("systemctl is-active template-crash-12.service")
    storage.succeed("image-template audit-refuse")
    swept = storage.succeed("image-template retire-unconfigured 11")
    assert int(swept.split("retired=")[1].split()[0]) >= 1, swept
    storage.succeed("test -z \"$(zfs list -H -o name,mounted -r tank/lilly | grep '\\tno$')\"")
    storage.succeed("image-template warm 11", "image-template audit")

# @cc [owner:ghuntley,label:verification;recovery] copy-child-holds-both-native-locks
# Hold the actual copier inside its copy syscall and pause its placement broker
# before killing the BEAM caller. Kernel offload otherwise completes the copy
# before it can be observed. The copier's open descriptors MUST retain both
# placement and source locks until it is reaped; production retry MUST recover
# the partial destination.
with subtest("caller death cannot release either side of an in-flight template copy"):
    storage.succeed("image-template ensure 10", "rm -f /run/template-copy-owner")
    storage.succeed(
        "mkdir -p /run/template-slow/bin",
        "ln -sf /etc/template-copy-slow /run/template-slow/bin/lilly-image-copy",
    )
    storage.succeed(
        "systemd-run --unit=template-vm-copy --property=KillMode=process "
        "--setenv=TEMPLATE_SLOW=1 image-template copy 10"
    )
    pending = "/pool/vms/dddddddd-dddd-4ddd-8ddd-000000000010/.rootfs.pending"
    child_pid = int(
        storage.succeed(
            "timeout 90 sh -c "
            + shlex.quote(
                "while [ ! -f " + pending + " ]; do sleep 0.01; done; "
                "owner=$(cat /run/template-copy-owner); copier=; "
                'while [ -z "$copier" ]; do '
                "for p in $(pgrep -P $owner) $(for c in $(pgrep -P $owner); do pgrep -P $c; done); do "
                "if readlink /proc/$p/fd/* 2>/dev/null | grep -q '^/pool/.lilly-templates/locks/'; "
                "then copier=$p; fi; done; sleep 0.01; done; "
                "kill -STOP $owner; printf '%s' \"$copier\""
            )
        ).strip()
    )
    owner_pid = int(storage.succeed("cat /run/template-copy-owner").strip())
    placement_lock = "/run/template-placement-10/owner.lock"
    descriptors = storage.succeed(f"readlink /proc/{child_pid}/fd/*").splitlines()
    assert placement_lock in descriptors
    source_leases = [
        path for path in descriptors if path.startswith("/pool/.lilly-templates/locks/")
    ]
    assert len(source_leases) == 1 and source_leases[0].endswith("/owner.lock")
    source_lock = source_leases[0]
    try:
        storage.succeed("systemctl kill --kill-whom=main --signal=KILL template-vm-copy.service")
        storage.wait_until_fails("systemctl is-active --quiet template-vm-copy.service")
        storage.succeed(f"test -d /proc/{child_pid}")
        storage.fail("flock -n " + shlex.quote(placement_lock) + " true")
        storage.fail("flock -n " + shlex.quote(source_lock) + " true")
    finally:
        storage.execute(f"kill -CONT {owner_pid}")
    storage.wait_until_fails(f"test -d /proc/{child_pid}")
    storage.wait_until_succeeds("flock -n " + shlex.quote(placement_lock) + " true")
    storage.wait_until_succeeds("flock -n " + shlex.quote(source_lock) + " true")
    storage.succeed("rm -rf /run/template-slow")
    storage.succeed(
        "image-template copy 10", "image-template ready 10", "image-template delete-vm 10"
    )
    storage.succeed("image-template ensure 8", "image-template warm 8")

with subtest("independent placement cleanup succeeds after template retirement"):
    storage.succeed("image-template delete-vm 1", "image-template audit")


def placement(number: int) -> str:
    return "dddddddd-dddd-4ddd-8ddd-" + str(number).rjust(12, "0")


def traced_prepare(number: int) -> tuple[int, list[str]]:
    output = storage.succeed(
        f"TEMPLATE_TRACE=1 TEMPLATE_PLACEMENT={number} image-template prepare-trace 8"
    )
    held = int(output.split("prepare_us=")[1].split()[0])
    lines = storage.succeed("cat /run/template-trace-result").splitlines()
    return held, lines


def report(label: str, held: int, lines: list[str]) -> tuple[int, int]:
    zfs = [line for line in lines if line.split()[0] in ("zfs", "zpool")]
    whole = [line for line in lines if line.startswith("zfs list") and line.endswith(" tank/lilly")]
    recursive = [line for line in whole if " -r" in line or "-Hpr" in line]
    print(
        f"ADR-0152 {label}: utilities={len(lines)} zfs={len(zfs)} "
        f"whole_pool_recursive={len(recursive)} held_us={held}"
    )
    for line in lines:
        print(f"ADR-0152 {label} trace: {line}")
    return len(zfs), len(recursive)


# @cc [owner:ghuntley,label:verification;capacity] lean-prepare-native-command-count
# The pool-locked part of Disk preparation MUST be measured on real ZFS with
# every zfs, zpool and findmnt invocation logged: a fresh claim, and a resume of an
# already bound placement (ADR-0152). The claim reads the pool once and
# re-verifies it once after its own mutation; the resume reads it once. The
# zfs/zpool and whole-pool recursive listing counts are bounded at the values
# measured for that design (before it: 46/12 and 28/7). Hold times are
# reported evidence, not a timing SLO.
with subtest("pool-locked preparation native command count"):
    storage.succeed(
        "mkdir -p /run/template-trace/bin",
        "for u in zfs zpool findmnt; do "
        "ln -sf /etc/template-trace /run/template-trace/bin/$u; done",
    )
    templates = storage.succeed("zfs list -H -r -o name tank/lilly | grep -c /template- || true")
    print(f"ADR-0152 templates={templates.strip()}")
    held, lines = traced_prepare(26)
    zfs, recursive = report("claim", held, lines)
    assert zfs <= 26 and recursive <= 6, (zfs, recursive)
    assert storage.succeed(
        f"zfs get -H -o value lilly:vm tank/lilly/vm-{placement(26)}"
    ).strip() == placement(26)
    held, lines = traced_prepare(26)
    zfs, recursive = report("resume", held, lines)
    assert zfs <= 12 and recursive <= 3, (zfs, recursive)
    storage.succeed("TEMPLATE_PLACEMENT=26 image-template copy 8")
    storage.succeed("TEMPLATE_PLACEMENT=26 image-template ready 8", "image-template audit-any")
    storage.succeed("TEMPLATE_PLACEMENT=26 image-template delete-vm 8", "image-template audit-any")
    storage.succeed("rm -rf /run/template-trace")

with subtest("bounded catalog retains interrupted publications and falls back without growth"):
    storage.succeed(
        "remaining=$((4096 - $(ls /pool/.lilly-templates/records | wc -l))); "
        "for n in $(seq 1 $remaining); do "
        "mkdir -m 700 /pool/.lilly-templates/records/$(printf 'eeeeeeee-eeee-4eee-8eee-%012d' $n); done"
    )
    storage.succeed("image-template expect-budget-refusal 9", "image-template warm 8")
    storage.succeed("test $(ls /pool/.lilly-templates/records | wc -l) -eq 4096")

with subtest("replacement dataset GUID cannot inherit a ready incarnation"):
    template = storage.succeed("zfs list -H -r -o name tank/lilly | grep /template-").strip()
    path = storage.succeed(f"zfs get -H -o value mountpoint {template}").strip()
    nonce = storage.succeed(f"zfs get -H -o value lilly:nonce {template}").strip()
    storage.succeed(f"zfs destroy {template}")
    storage.succeed(
        f"zfs create -o mountpoint={path} -o exec=off -o devices=off -o setuid=off "
        "-o lilly:host=aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa "
        "-o lilly:pool=bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb "
        f"-o lilly:vm=- -o lilly:nonce={nonce} {template}"
    )
    storage.succeed(f"chmod 0700 {path}", f"zfs set readonly=on {template}")
    storage.succeed(
        "image-template refuse 8", "image-template audit-refuse 8", "image-template refuse 8"
    )
    storage.succeed(f"zfs list {template}")
