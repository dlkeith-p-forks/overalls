"""Check a real native transport reset in a disposable nested-KVM guest."""

host.start()
host.wait_for_unit("multi-user.target")
host.succeed("test -c /dev/kvm")
host.succeed("mkfs.ext4 -F -q /dev/vdb && mkdir -p /work && mount /dev/vdb /work")
# @cc [owner:ghuntley,label:verification] native-reset-failure-evidence
# Qualification MUST retain the serial transcript even on failure. Nested
# guest boot and snapshot transfer MAY take longer under concurrent builds;
# the bounded timeout MUST permit the probe's own stage deadlines to finish.
try:
    host.succeed(
        "python3.13 /etc/native-reset-tools/native_reset.py"
        " --image /etc/native-reset-image"
        " --probe /etc/native-reset-probes/bin/freebsd-reset-probe"
        f" --vmm {vmm} --work /work/native-reset",
        timeout=600,
    )
finally:
    for evidence in ("serial.log", "vmm-stderr.log", "vmm.log", "restore.log"):
        evidence_path = "/work/native-reset/" + evidence
        if host.execute("test -f " + evidence_path)[0] == 0:
            host.copy_from_vm(evidence_path)
host.succeed(
    "jq -e '.native_admission == false and .api_statuses == [204,204,204]"
    " and .oracle.idle_error == 54 and .oracle.accept_error == 0"
    " and .oracle.read_error > 0 and .oracle.write_error > 0"
    ' and .oracle.fresh_socket == "current-cid-revalidated"'
    "' /work/native-reset/reset-receipt.json"
)
host.copy_from_vm("/work/native-reset/reset-receipt.json")
