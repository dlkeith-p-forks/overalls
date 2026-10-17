def assert_boot_profile(vm: str, finished: bool = True) -> None:
    """@cc [owner:ghuntley,label:verification] zfs-guest-boot-profile-evidence
    The retained console MUST carry host monotonic line offsets and the guest's
    bounded boot profile with its manager phase line. A guest whose boot
    transaction can finish MUST also report systemd's Startup finished line.
    Only marker-prefixed profile lines are printed; other console bytes stay in
    the host file except bounded serial diagnostics on failure.
    """
    boot_log = f"/var/lib/lilly/vms/{vm}/boot.log"
    try:
        storage.wait_until_succeeds(f"grep -aq 'lilly-boot-report: end' {boot_log}", timeout=180)
    except Exception:
        # Serial console only (no terminal-session bytes), as in guest-diagnostics.
        print(
            storage.succeed(
                f"grep -av 'overalls-ssh-sync' {boot_log} | tr -d '\\r' | tail -n 120 | cut -c1-200"
            )
        )
        raise
    storage.succeed(f"grep -aqE '^\\[\\+[0-9]+\\.[0-9]{{3}}\\] ' {boot_log}")
    storage.succeed(f"grep -aqE 'lilly-boot-report: manager since-kernel initrd=' {boot_log}")
    if finished:
        storage.succeed(
            f"grep -aqE '^\\[\\+[0-9.]+\\] lilly-boot-report: Startup finished' {boot_log}"
        )
    # Console volume up to the report: lines and bytes the serial port carried.
    print(
        storage.succeed(
            f"sed -n '1,/lilly-boot-report: begin/p' {boot_log} | wc -lc"
            " | sed 's/^/boot-log lines+bytes before report: /'"
        )
    )
    # Serial lines end in CRLF; strip CR so the Nix log keeps each line's text.
    print(
        storage.succeed(
            f"grep -aE 'lilly-boot-report: |lilly-guest boot complete' {boot_log} | tr -d '\\r'"
        )
    )
