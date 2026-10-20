prepare(host)
pool(host, "/dev/vdc")
run(host, "interrupted-growth", "/work/native")
host.succeed(
    "jq -e '.version == 1 and .native_admission == false"
    f' and .os == "{os_name}"'
    " and (.checks | length == 8) and (.stages | length == 2)"
    " and (.boot_ids | unique | length == 3)"
    " and (.root_capacity_bytes | length == 3)"
    " and .root_capacity_bytes[1] > .root_capacity_bytes[0]"
    " and .root_capacity_bytes[2] > .root_capacity_bytes[1]"
    " and all(.stages[]; .observed_writes_past_old_end >= .kill_after_writes_past_old_end)'"
    " /work/native/interrupted-growth-receipt.json"
)
print(host.succeed("cat /work/native/interrupted-growth-receipt.json"), flush=True)
host.copy_from_vm("/work/native/interrupted-growth-receipt.json")
