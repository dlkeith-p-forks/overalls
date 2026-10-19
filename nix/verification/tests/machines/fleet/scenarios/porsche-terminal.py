# @cc [owner:ghuntley,label:verification;security] porsche-terminal-attach-native
# SSH attach acceptance MUST drive the real OpenSSH client through Porsche's
# `terminal attach` into the browser's personal terminal session on a real
# guest. It MUST show both attaches share that session, read-only input never
# reaches the guest, key revocation ends a live attach with exit 3 within 5 s
# of the committed removal, and no typed or echoed bytes reach any journal.
with subtest("Porsche SSH attach shares the browser terminal session"):
    attach_root = porsche_root + "/attach"
    attach_marker = uuid.uuid4().hex[:16]
    client.succeed(f"install -d -m 700 -o tester -g users {attach_root}")
    # The relay feeds an append-only input file to `ssh -tt` and records only
    # the exit status and wall clock; terminal bytes stay in owner-only files.
    attach_program = "\n".join(
        [
            "import json, os, subprocess, sys, threading, time",
            "arguments, base = json.loads(sys.argv[1]), sys.argv[2]",
            "out = open(base + '.out', 'wb')",
            "err = open(base + '.err', 'wb')",
            "process = subprocess.Popen(arguments, stdin=subprocess.PIPE, stdout=out, stderr=err)",
            "def feed() -> None:",
            "    offset = 0",
            "    while process.poll() is None:",
            "        if os.path.exists(base + '.eof'):",
            "            process.stdin.close()",
            "            return",
            "        try:",
            "            data = open(base + '.in', 'rb').read()",
            "        except FileNotFoundError:",
            "            data = b''",
            "        if len(data) > offset:",
            "            try:",
            "                process.stdin.write(data[offset:])",
            "                process.stdin.flush()",
            "            except BrokenPipeError:",
            "                return",
            "            offset = len(data)",
            "        time.sleep(0.1)",
            "threading.Thread(target=feed, daemon=True).start()",
            "status = process.wait()",
            "with open(base + '.status.tmp', 'w') as file:",
            "    json.dump({'status': status, 'exited_at_ms': time.time_ns() // 1_000_000}, file)",
            "os.rename(base + '.status.tmp', base + '.status')",
            "",
        ]
    )
    client.succeed(
        "printf %s " + shlex.quote(attach_program) + f" > {attach_root}/relay.py"
        f" && chown tester:users {attach_root}/relay.py"
    )

    attach_sessions: list[str] = []

    def attach_personal_session() -> bool:
        opened = operator(
            m1,
            dict(
                action="terminal-personal-session",
                owner_id=users["owner_id"],
                vm_id=terminal_vm["vm_id"],
            ),
        )
        if opened["session_id"] is None:
            # Only readiness refusals (a host stream still registering) retry.
            assert opened["reason"] in ("terminal_unavailable", "terminal_open_pending"), opened
            return False
        attach_sessions.append(str(opened["session_id"]))
        return True

    eventually(attach_personal_session, timeout=180)
    attach_session = attach_sessions[0]
    assert str(uuid.UUID(attach_session)) == attach_session

    def attach_start(name: str, read_only: bool) -> None:
        command = "terminal attach " + terminal_vm["vm_id"] + " " + attach_session
        if read_only:
            command += " --read-only"
        arguments = porsche_arguments(command)[:-1]
        arguments = [arguments[0], "-tt", *arguments[1:], command]
        client.succeed(
            f"systemd-run --quiet --no-block --unit=porsche-attach-{name} "
            "--property=User=tester --property=Environment=HOME=/home/tester "
            "--property=StandardOutput=null --property=StandardError=null "
            + shlex.join(
                [
                    "/run/current-system/sw/bin/python3",
                    attach_root + "/relay.py",
                    json.dumps(arguments),
                    attach_root + "/" + name,
                ]
            )
        )

    def attach_header(name: str) -> dict[str, object]:
        lines = client.succeed(f"cat {attach_root}/{name}.err 2>/dev/null || true").splitlines()
        for line in lines:
            if line.startswith("{"):
                value: object = json.loads(line)
                assert isinstance(value, dict)
                return {str(key): item for key, item in value.items()}
        return {}

    def attach_type(name: str, text: str) -> None:
        client.succeed("printf %s " + shlex.quote(text) + f" >> {attach_root}/{name}.in")

    def attach_saw(name: str, text: str) -> bool:
        return (
            client.execute("grep -aqF " + shlex.quote(text) + f" {attach_root}/{name}.out")[0] == 0
        )

    def attach_status(name: str) -> dict[str, int] | None:
        code, output = client.execute(f"cat {attach_root}/{name}.status")
        if code != 0:
            return None
        value: object = json.loads(output)
        assert isinstance(value, dict)
        fields = {str(key): item for key, item in value.items()}
        status, exited = fields.get("status"), fields.get("exited_at_ms")
        assert isinstance(status, int) and isinstance(exited, int), value
        return {"status": status, "exited_at_ms": exited}

    attach_start("rw", read_only=False)
    eventually(lambda: attach_header("rw") != {}, timeout=60)
    rw_header = attach_header("rw")
    assert rw_header["attached"] is True and rw_header["mode"] == "rw", rw_header
    attach_start("ro", read_only=True)
    eventually(lambda: attach_header("ro") != {}, timeout=60)
    ro_header = attach_header("ro")
    assert ro_header["attached"] is True and ro_header["mode"] == "ro", ro_header

    # The shell evaluates the arithmetic, so only real guest output (never
    # the pty echo of the typed line) contains the "-42" form.
    attach_type("rw", f"echo rw-{attach_marker}-$((6*7))\n")
    eventually(lambda: attach_saw("rw", f"rw-{attach_marker}-42"), timeout=60)
    eventually(lambda: attach_saw("ro", f"rw-{attach_marker}-42"), timeout=60)

with subtest("read-only SSH attach input never reaches the guest"):
    attach_type("ro", f"echo ro-{attach_marker}-$((6*7))\n")
    attach_type("rw", f"echo fence-{attach_marker}-$((5*5))\n")
    eventually(lambda: attach_saw("rw", f"fence-{attach_marker}-25"), timeout=60)
    eventually(lambda: attach_saw("ro", f"fence-{attach_marker}-25"), timeout=60)
    for attached in ("rw", "ro"):
        assert not attach_saw(attached, f"ro-{attach_marker}"), attached
    # End of input detaches the read-only viewer with an ordinary close.
    client.succeed(f"touch {attach_root}/ro.eof")
    eventually(lambda: attach_status("ro") is not None, timeout=30)
    ro_ended = attach_status("ro")
    assert ro_ended is not None and ro_ended["status"] == 0, ro_ended

with subtest("SSH key revocation closes a live attach within five seconds"):
    owner_public = client.succeed(f"cat {porsche_root}/owner.pub").strip()
    revoked = operator(
        m1, dict(action="ssh-key-revoke", owner_id=users["owner_id"], public_key=owner_public)
    )
    revoked_at = int(str(revoked["revoked_at_ms"]))
    eventually(lambda: attach_status("rw") is not None, timeout=30)
    ended = attach_status("rw")
    assert ended is not None and ended["status"] == 3, ended
    # Guest clocks share the host's kvm-clock; the removal time is taken after
    # its transaction committed, so this bounds commit-to-exit latency.
    assert ended["exited_at_ms"] - revoked_at <= 5_000, ended["exited_at_ms"] - revoked_at
    assert sql("SELECT count(*) FROM terminal_tickets WHERE ssh_session_id IS NOT NULL") == "0"

with subtest("no SSH attach terminal bytes reach any journal"):
    for machine in [*marshalls, *provisioners, client]:
        code, _ = machine.execute(
            "journalctl --no-pager -o cat | grep -aqF " + shlex.quote(attach_marker)
        )
        assert code != 0, machine.name
