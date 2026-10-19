"""Exercise a closed native image's production daemons on an isolated test host."""

import json
import shlex

host.start()
host.wait_for_unit("multi-user.target")
host.succeed("test -c /dev/kvm")
host.succeed("mkfs.ext4 -F -q /dev/vdb && mkdir -p /work && mount /dev/vdb /work")
host.succeed("ip tuntap add native0 mode tap")
host.succeed("ip link set native0 up")
host.succeed("ip address add 10.10.0.1/32 dev native0")
host.succeed("ip route add 10.10.0.203/32 dev native0 src 10.10.0.1")
host.succeed("ip address add 169.254.254.1/32 dev lo")
host.succeed("ip address add 1.1.1.1/32 dev lo")
try:
    extra = f" --os-name {os_name}" + (" --growth" if growth else "")
    if github:
        extra += (
            " --github-tools-release /etc/native-github-tools"
            " --github-executor-release /etc/native-github-executors"
        )
    host.succeed(
        f"python3 /etc/native-service-tools/{service_runner}"
        " --image /etc/overalls-native-service-image"
        f" --vmm {vmm} --tap native0 --fixture /etc/native-service-fixture"
        f" --work /work/native-services{extra}",
        timeout=1400 if growth or crash else 800,
    )
    boot_count = 3 if growth else 2
    expected_checks: list[str] = [
        "mmdsv2-current-boot-kernel",
        "assigned-address-reachable",
        "readiness-withheld-without-ssh-authority",
        "trust-installed-and-stale-refused",
        "flush-current-boot-and-refusals",
        "workspace-stale-foreign-malformed-refused",
        "workspace-native-https-shallow-checkout-and-exact-bytes",
        "workspace-exact-git-ownership-and-unrelated-root-refusal",
        "terminal-hello-ping-and-refusals",
        "terminal-managed-pty-input-resize-replay-and-token-refusal",
        "kernel-current-boot-rechecked",
        "complete-readiness-after-isolated-authority",
        "ssh-certified-host-and-foreign-ca-refusal",
        "ssh-managed-uid-gid-bash-and-passwordless-sudo",
        "ssh-foreign-key-root-foreign-user-and-password-refusals",
        "ssh-login-receipt-before-startup-and-client-environment",
        "executor-private-https-fixed-command-completed",
        "executor-current-heartbeat-withdrawal-before-command-deadline",
        "executor-whole-group-death-no-result-and-fresh-fence-completion",
        "first-boot-sigkill-and-final-clean-shutdown"
        if crash
        else "ssh-triggered-clean-guest-shutdown",
        "new-mmds-epoch-challenge-and-boot-id",
        "previous-boot-protocol-refused",
        "home-bytes-retained-across-abrupt-restart"
        if crash
        else "home-bytes-retained-across-clean-reboot",
        "ssh-host-key-rotated-across-abrupt-restart"
        if crash
        else "ssh-host-key-rotated-across-clean-reboot",
        "all-boots-core-services-and-final-boot-executor-withdrawal"
        if github
        else "all-boots-complete-service-oracles",
    ]
    receipt_filter: str = (
        ".native_admission == false and "
        "((.checks | sort) == (($base + (if $manifest[0].git_identity_version == 1 "
        'then ["all-boots-current-mmds-git-config-and-commit-attribution"] else [] end)) | sort))'
        f" and (.boot_ids | unique | length == {boot_count})"
    )
    host.succeed(
        "jq -e --slurpfile manifest /etc/overalls-native-service-image/manifest.json"
        f" --argjson base {shlex.quote(json.dumps(expected_checks))} "
        + shlex.quote(receipt_filter)
        + " /work/native-services/service-receipt.json"
    )
    host.copy_from_vm("/work/native-services/service-receipt.json")
    host.copy_from_vm("/work/native-services/control-0.json")
    host.copy_from_vm("/work/native-services/control-1.json")
    if github:
        host.succeed(
            "jq -e '.version == 1 and .native_admission == false"
            " and (.checks | length == 8) and (.boots | length == 2)"
            ' and .boots[0].outcome == "installed"'
            ' and .boots[1].outcome == "already_current"\''
            " /work/native-services/github-tools-receipt.json"
        )
        host.copy_from_vm("/work/native-services/github-tools-receipt.json")
    if growth:
        growth_checks = 5 if os_name == "freebsd" else 8
        host.copy_from_vm("/work/native-services/control-2.json")
        host.succeed(
            f"jq -e '.native_admission == false and (.checks | length == {growth_checks})"
            " and (.boot_ids | unique | length == 3) and (.root_bytes | length == 3)"
            " and .root_bytes[1] > .root_bytes[0] and .root_bytes[2] > .root_bytes[1]'"
            " /work/native-services/growth-receipt.json"
        )
        host.copy_from_vm("/work/native-services/growth-receipt.json")
    if recovery:
        host.succeed(
            "test $(find /work/native-services -path '*/recovery-*/receipt.json' | wc -l) -eq 2"
        )
        host.succeed("mkdir /work/recovery-receipts")
        host.succeed(
            "for receipt in /work/native-services/recovery-*/receipt.json; do "
            'directory=$(basename "$(dirname "$receipt")"); '
            "jq -e '(.checks | length == 5) and .native_admission == false' \"$receipt\"; "
            'cp "$receipt" "/work/recovery-receipts/$directory.json"; done'
        )
        host.copy_from_vm("/work/recovery-receipts")
    if crash:
        integrity = (
            "ufs-snapshot-background-fsck"
            if os_name == "freebsd"
            else "zfs-completed-zero-error-scrub"
        )
        host.succeed(
            f'jq -e \'.version == 1 and .os == "{os_name}" and .native_admission == false'
            " and (.checks | length == 8)"
            ' and .boot_endings == ["sigkill", "clean"]'
            " and (.boot_ids | unique | length == 2)"
            f' and .native_integrity == "{integrity}"\''
            " /work/native-services/crash-recovery-receipt.json"
        )
        host.copy_from_vm("/work/native-services/crash-recovery-receipt.json")
finally:
    status, serial = host.execute("tail -c 131072 /work/native-services/serial.log 2>/dev/null")
    if status == 0:
        print(serial, flush=True)
        host.copy_from_vm("/work/native-services/serial.log")
