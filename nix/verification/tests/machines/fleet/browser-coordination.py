def browser_probe(vm: ProvisionedPlacement, *, prompt_only: bool = False) -> None:
    rendezvous = "/var/lib/fleet-browser/rendezvous"
    client.succeed(
        "install -d -m 700 -o tester -g users /var/lib/fleet-browser /home/tester/.pki /home/tester/.pki/nssdb "
        + rendezvous
    )
    client.succeed("printf '%s' '{\"phase\":\"starting\"}' >" + rendezvous + "/state.json")
    operator(
        m1,
        dict(
            action="refresh-browser-tokens",
            source=root + "/users.json",
            output=root + "/browser-users.json",
        ),
    )
    transfer(m1, root + "/browser-users.json", client, "/var/lib/fleet-browser/users.json")
    client.succeed(
        "chown tester:users /var/lib/fleet-browser/users.json && chmod 600 /var/lib/fleet-browser/users.json"
    )
    client.succeed(f"install -m 644 {root}/ca.crt /var/lib/fleet-browser/ca.crt")
    client.succeed(
        "test -f /home/tester/.pki/nssdb/cert9.db || sudo -u tester certutil -N -d sql:/home/tester/.pki/nssdb --empty-password"
    )
    client.succeed(
        "sudo -u tester certutil -A -d sql:/home/tester/.pki/nssdb -n fleet-root -t 'C,,' -i /var/lib/fleet-browser/ca.crt"
    )
    before = process_snapshot(vm)
    client.succeed(
        "systemd-run --quiet --no-block --unit=fleet-browser --property=User=tester "
        "--property=Environment=HOME=/home/tester --property=WorkingDirectory=/home/tester "
        "--property=StandardOutput=append:/var/lib/fleet-browser/public.log "
        "--property=StandardError=append:/var/lib/fleet-browser/public.log --property=TimeoutStartSec=900 --service-type=oneshot "
        "/run/current-system/sw/bin/fleet-browser /var/lib/fleet-browser/users.json "
        + shlex.quote(vm["vm_id"])
        + " "
        + rendezvous
        + (" --prompt-only" if prompt_only else "")
    )

    def pin(chosen: int | None) -> None:
        for number in [1, 2, 3]:
            state = "ready" if chosen is None or chosen == number else "maint"
            command = f"set server marshall_nodes/m{number} state {state}\n"
            assert not proxy.succeed(
                "printf %s "
                + shlex.quote(command)
                + " | socat - UNIX-CONNECT:/run/haproxy/fleet.sock"
            ).strip()
        # Leaving maintenance resumes health checks; an acknowledged admin
        # command alone does not mean the selected backend is serving yet.
        client.wait_until_succeeds(
            f"curl --fail --silent --cacert {root}/ca.crt https://control.example.test/health/ready",
            timeout=30,
        )

    completed: set[int] = set()

    def service_browser() -> bool:
        message: dict[str, object] = json.loads(client.succeed("cat " + rendezvous + "/state.json"))
        if message["phase"] == "request":
            sequence = message["sequence"]
            assert type(sequence) is int and 1 <= sequence <= 32
            if sequence not in completed:
                assert sequence == len(completed) + 1
                action, node = message["action"], message["node"]
                assert isinstance(node, int) or node is None
                if action == "pin":
                    assert node in [None, 1, 2, 3]
                    pin(node)
                elif action == "crash":
                    assert node == 1
                    pin(2)
                    # Hold a real transaction on the VM before losing the
                    # entire machine. A process kill closes TCP and cannot
                    # establish recovery from an abandoned remote transaction.
                    held = root + "/held-transaction.json"
                    request = request_file(m1, dict(action="hold-transaction", vm_id=vm["vm_id"]))
                    m1.succeed(
                        "systemd-run --quiet --unit=fleet-held-transaction --property=Type=exec "
                        "--setenv=PATH=/run/current-system/sw/bin "
                        "--property=StandardOutput=null --property=StandardError=null fleet-op "
                        + shlex.quote(request)
                    )
                    m1.wait_for_file(held, timeout=30)
                    backend = json.loads(m1.succeed("cat " + held))["pid"]
                    assert type(backend) is int and backend > 0
                    connections = sql_json(
                        "SELECT json_agg(pid) FROM pg_stat_activity WHERE "
                        "application_name IN ('marshall:m1','marshall:fleet-operator-m1')"
                    )
                    assert isinstance(connections, list)
                    assert backend in connections and all(
                        type(pid) is int and pid > 0 for pid in connections
                    )
                    pids = ",".join(map(str, connections))
                    m1.crash()
                    lost_at = time.monotonic()
                    try:
                        eventually(
                            lambda: (
                                sql(f"SELECT count(*) FROM pg_stat_activity WHERE pid={backend}")
                                == "0"
                            ),
                            timeout=20,
                        )
                        # Also reclaim idle pools and the notifier from the lost
                        # machine; an idle-transaction timeout cannot release them.
                        eventually(
                            lambda: (
                                sql(f"SELECT count(*) FROM pg_stat_activity WHERE pid IN ({pids})")
                                == "0"
                            ),
                            timeout=max(1, 35 - (time.monotonic() - lost_at)),
                        )
                    except AssertionError:
                        print(
                            "Remaining lost-node backends:",
                            sql(f"SELECT count(*) FROM pg_stat_activity WHERE pid IN ({pids})"),
                        )
                        print("Database waits:", database_waits())
                        raise
                elif action == "restore":
                    assert node == 1
                    m1.start()
                    m1.wait_for_unit("marshall-m1.service")
                    m1.wait_until_succeeds(
                        f"curl --fail --silent --cacert {root}/ca.crt https://m1:4443/health/ready"
                    )
                    if porsche_enabled:
                        m1.wait_for_unit("porsche.service")
                        m1.wait_for_open_port(22)
                else:
                    raise AssertionError("Unknown browser coordination request")
                client.succeed(f"touch {rendezvous}/{sequence}.done")
                completed.add(sequence)
        elif message["phase"] == "finished":
            if not message["passed"]:
                print(
                    host_for(vm).succeed(
                        "fleet-relocation-guest terminal-diagnostics "
                        + shlex.quote(vm["placement_id"]),
                        timeout=240,
                    )
                )
                print("Database waits:", database_waits())
                print(
                    "Active grants for terminal VM:",
                    sql(
                        "SELECT count(*) FROM access_grants WHERE archived_at IS NULL AND vm_id='"
                        + vm["vm_id"]
                        + "'"
                    ),
                )
                # Counts only: how many terminal sessions the VM holds, by kill state.
                print(
                    "Terminal sessions for VM by kill state:",
                    sql(
                        "SELECT coalesce(string_agg(kill_status || '=' || n, ','), 'none') FROM "
                        + "(SELECT kill_status, count(*) AS n FROM terminal_sessions WHERE vm_id='"
                        + vm["vm_id"]
                        + "' GROUP BY kill_status) AS counts"
                    ),
                )
            if not message["passed"]:
                # Allowlisted failure diagnostics the worker published itself:
                # fixed stage name, exception class name, pageerror category
                # counters and route/status navigation tail. Nothing else.
                for key in ("failure_stage", "failure_error", "browser_errors", "navigation_tail"):
                    if key in message:
                        print(
                            "Browser worker diagnosis:",
                            key,
                            "=",
                            json.dumps(message[key]),
                            flush=True,
                        )
            # If candidacy keys tell us nothing, list which keys the worker
            # published at all (names only; values stay private).
            if not message["passed"] and all(
                k not in message for k in ("failure_stage", "failure_error")
            ):
                print(
                    "Browser worker made no diagnosis; rendezvous keys:",
                    sorted(message.keys()),
                    flush=True,
                )
            assert message["passed"], "Browser acceptance failed"
            client.wait_until_succeeds(
                "systemctl show -p ActiveState --value fleet-browser.service | grep -qxE 'inactive|failed'",
                timeout=30,
            )
            assert (
                client.succeed("systemctl show -p Result --value fleet-browser.service").strip()
                == "success"
            )
            return True
        else:
            assert message["phase"] == "starting"
        if client.execute("systemctl is-failed --quiet fleet-browser.service")[0] == 0:
            raise AssertionError("Browser worker exited without completing its rendezvous")
        return False

    try:
        # The full journey (fifty terminals, graphics, Marshall loss, sharing and
        # revocation) can exceed ten minutes on a loaded verification host.
        eventually(service_browser, timeout=900)
        assert process_snapshot(vm) == before
    finally:
        # The helper's allowlisted log must survive coordinator assertion failures.
        print(
            client.succeed(
                "test ! -f /var/lib/fleet-browser/public.log || cat /var/lib/fleet-browser/public.log"
            ),
            flush=True,
        )
