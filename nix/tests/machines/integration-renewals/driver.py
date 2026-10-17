"""Additional strictly typed journey after ordinary team resources are usable."""


class RenewalOrigin(TypedDict):
    accepts: int
    closed: bool
    timed_out: bool


def renewal_origin(case: str) -> RenewalOrigin | None:
    assert case in ("member", "attachment")
    path = "/run/galileo-origin/renewal-" + case + ".json"
    status, output = egress.execute("cat " + path)
    if status:
        return None
    parsed: object = json.loads(output)
    fields = object_fields(parsed)
    assert set(fields) == {"accepts", "closed", "timed_out"}
    accepts, closed, timed_out = fields["accepts"], fields["closed"], fields["timed_out"]
    assert isinstance(accepts, int) and not isinstance(accepts, bool) and accepts > 0
    assert isinstance(closed, bool) and isinstance(timed_out, bool)
    return {"accepts": accepts, "closed": closed, "timed_out": timed_out}


def renewal_outcomes(vm_id: str, cursor: str) -> list[str]:
    """Closed Galileo renewal outcomes on the VM's host after this cursor.

    Renewals travel over Galileo's control WebSocket (ADR-0142), so each one is
    observed through its catalogued galileo.lease_renewal event, never through
    proxy request logs.
    """
    host, _ = current_placement(vm_id)
    return journal_reasons(host, "galileo.service", cursor, "galileo.lease_renewal")


def renewal_active(vm_id: str) -> int:
    host, _ = current_placement(vm_id)
    parsed: object = json.loads(
        host.succeed(
            "curl --fail --silent --unix-socket /run/galileo/proxy.sock http://galileo/metrics"
        )
    )
    gauges = object_fields(object_fields(parsed)["gauges"])
    active = gauges["galileo_active_requests"]
    assert isinstance(active, int) and not isinstance(active, bool) and active >= 0
    return active


def origin_connections() -> int:
    """Count TLS acceptance before the origin validates any HTTP credential."""
    return int(egress.succeed("cat /run/galileo-origin/connections").strip())


def revoke_open_integration(case: str, withdraw: Callable[[], object]) -> None:
    """@cc [owner:ghuntley,label:verification;security] integration-open-renewal-refusal
    Each real guest request MUST have its own origin counter and journal cursor,
    a granted renewal over the control WebSocket while its original socket remains open,
    then an ordinary authority withdrawal. Refusal MUST have one refused renewal outcome and
    exactly one Marshall unauthorized event, actual origin EOF/reset and a failed
    completed guest request with no extra origin acceptance. Elapsed time alone
    MUST NOT establish successful renewal or cancellation.
    """
    assert case in ("member", "attachment")
    assert renewal_origin(case) is None
    assert renewal_active(member_vm) == 0
    before = int(egress.succeed("cat /run/galileo-origin/count").strip())
    connections_before = origin_connections()
    galileo_host, _ = current_placement(member_vm)
    renewal_cursor = journal_cursor(galileo_host, "galileo.service")
    command = (
        "sudo systemd-run --quiet --unit=fleet-renewal-"
        + case
        + " --property=TimeoutStartSec=70 --property=StandardOutput=file:/tmp/renewal-"
        + case
        + ".out --property=StandardError=file:/tmp/renewal-"
        + case
        + ".err curl --fail --silent --show-error --max-time 60 "
        + "https://directapi.integration.internal/renewal-"
        + case
        + " && printf started"
    )
    guest_command(member_vm, "member", command, "started")
    eventually(
        lambda: (
            renewal_origin(case) == {"accepts": 1, "closed": False, "timed_out": False}
            and "granted" in renewal_outcomes(member_vm, renewal_cursor)
            and renewal_active(member_vm) == 1
        ),
        timeout=20,
    )
    assert int(egress.succeed("cat /run/galileo-origin/count").strip()) == before + 1
    assert origin_connections() == connections_before + 1
    denial_cursors = [
        (machine, journal_cursor(machine, "marshall-" + machine.name + ".service"))
        for machine in marshalls
    ]
    withdraw()
    eventually(lambda: "refused" in renewal_outcomes(member_vm, renewal_cursor), timeout=5)
    refusal_observed_at = time.monotonic()
    eventually(
        lambda: (
            renewal_origin(case) == {"accepts": 1, "closed": True, "timed_out": False}
            and "refused" in renewal_outcomes(member_vm, renewal_cursor)
            and renewal_active(member_vm) == 0
        ),
        timeout=5,
    )
    assert time.monotonic() - refusal_observed_at <= 5
    # The completed failing curl is an independent client-side terminal state;
    # service inactivity or a disconnected origin alone cannot satisfy this.
    guest_command(
        member_vm,
        "member",
        "systemctl show --property=ExecMainStatus --value fleet-renewal-" + case,
        "22",
    )
    outcomes = renewal_outcomes(member_vm, renewal_cursor)
    assert outcomes.count("refused") == 1
    assert all(outcome in ("granted", "refused") for outcome in outcomes)
    reasons = [
        reason
        for machine, cursor in denial_cursors
        for reason in journal_reasons(
            machine,
            "marshall-" + machine.name + ".service",
            cursor,
            "galileo.authorization_denied",
        )
    ]
    assert reasons == ["unauthorized"]
    assert renewal_origin(case) == {"accepts": 1, "closed": True, "timed_out": False}
    assert int(egress.succeed("cat /run/galileo-origin/count").strip()) == before + 1
    assert origin_connections() == connections_before + 1
    integration_probe(member_vm, "member", False)
    assert origin_connections() == connections_before + 1


with subtest("removing actual team membership closes an already renewed integration attempt"):
    revoke_open_integration(
        "member", lambda: porsche("team member remove native-resources " + member_email)
    )
    porsche("team member add native-resources " + member_email + " member")
    integration_probe(member_vm, "member", True)

with subtest("detaching actual authority closes an already renewed integration attempt"):
    porsche("team member remove native-resources " + member_email)
    operator(dict(action="galileo-attach-direct", owner_id=users["owner"]["id"], vm_id=member_vm))
    integration_probe(member_vm, "member", True)
    revoke_open_integration(
        "attachment",
        lambda: operator(
            dict(action="galileo-detach-direct", owner_id=users["owner"]["id"], vm_id=member_vm)
        ),
    )
    operator(dict(action="galileo-attach-direct", owner_id=users["owner"]["id"], vm_id=member_vm))
    integration_probe(member_vm, "member", True)
    operator(dict(action="galileo-detach-direct", owner_id=users["owner"]["id"], vm_id=member_vm))
    porsche("team member add native-resources " + member_email + " member")
    integration_probe(member_vm, "member", True)
    ordinary_accounts()
