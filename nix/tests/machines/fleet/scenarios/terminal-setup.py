# Terminal acceptance needs one real writable guest. Capacity races retain their
# separate full-fleet scenario and its smaller image/disk assumptions.
with subtest("provision a personal-terminal guest with private account authority"):
    terminal_vm = provision_when_available(m1, "standard")
    assert terminal_vm["accepted"], (terminal_vm, capacity_snapshot())
    await_running(terminal_vm["vm_id"])
    vms = [terminal_vm]
