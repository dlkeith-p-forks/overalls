# @cc [owner:ghuntley,label:verification;security] fleet-agent-real-guest-roundtrip
# A shared VM operator prompts a stopped real guest. Marshall must wake it,
# Ziggy must obtain two model responses, and the guest must execute a fenced
# read_file through Audi private before the final answer. The model is an
# isolated deterministic provider fixture; no control or guest reply is forged.
import hashlib

with subtest("private guest agent path has authenticated host services"):
    m1.succeed("systemctl start fleet-audi-ca.service")
    m1.wait_for_open_port(14000)
    m1.wait_until_succeeds(
        f"curl --fail --silent --cacert {root}/ca.crt --resolve m1:15000:127.0.0.1 "
        f"https://m1:15000/roots/0 >{root}/audi-root.pem"
    )
    for machine in provisioners:
        if otel_guest_enabled:
            machine.wait_for_unit("opentelemetry-collector.service")
            machine.wait_for_unit("overalls-otel-guest.service")
        transfer(m1, root + "/audi-root.pem", machine, "/run/galileo-audi-root.pem")
        machine.succeed("chmod 0444 /run/galileo-audi-root.pem")
        machine.succeed("fleet-seal-audi-private")
        machine.wait_for_unit("audi-private.service")
        machine.wait_until_succeeds(
            "curl --fail --silent --unix-socket /run/ziggy/proxy.sock "
            "http://ziggy/health/ready | jq -e '.ready == true'",
            timeout=120,
        )

with subtest("shared operator prompt wakes guest and completes model tool round trip"):
    vm = provision_when_available(m1, "standard", disk_bytes=6_442_450_944)
    await_running(vm["vm_id"])
    host_for(vm).wait_until_succeeds(
        "fleet-galileo-guest agent-service " + shlex.quote(vm["placement_id"]), timeout=120
    )
    host_for(vm).wait_until_succeeds(
        "fleet-galileo-guest agent-route " + shlex.quote(vm["placement_id"]), timeout=120
    )
    eventually(
        lambda: (
            sql(
                "SELECT binary_sha256 FROM agent_executors WHERE root_id="
                f"(SELECT id FROM agent_roots WHERE vm_id='{vm['vm_id']}') "
                "AND invalidated_at IS NULL"
            )
            == agent_release_digest
        ),
        timeout=300,
    )
    host_for(vm).succeed(
        "fleet-galileo-guest agent-update "
        + shlex.quote(vm["placement_id"])
        + " "
        + agent_release_digest,
        timeout=120,
    )
    if not otel_guest_enabled:
        host_for(vm).succeed(
            "fleet-galileo-guest agent-reset "
            + shlex.quote(vm["placement_id"])
            + " "
            + agent_release_digest,
            timeout=120,
        )
        host_for(vm).wait_until_succeeds(
            "fleet-galileo-guest agent-update "
            + shlex.quote(vm["placement_id"])
            + " "
            + agent_release_digest,
            timeout=300,
        )
    operator(
        m1,
        dict(
            action="share",
            owner_id=users["owner_id"],
            vm_id=vm["vm_id"],
            email=users["member_email"],
            role="operator",
            key=str(uuid.uuid4()),
        ),
    )
    eventually(
        lambda: (
            sql(
                "SELECT count(*) FROM agent_executors WHERE root_id="
                f"(SELECT id FROM agent_roots WHERE vm_id='{vm['vm_id']}') "
                "AND expires_at > (clock_timestamp() AT TIME ZONE 'UTC')"
            )
            != "0"
        ),
        timeout=180,
    )
    lifecycle(vm["vm_id"], "stop")
    eventually(lambda: vm_state(vm["vm_id"]) == "stopped", timeout=180)
    submitted = operator(
        m2,
        dict(
            action="agent-prompt",
            actor_id=users["member_id"],
            vm_id=vm["vm_id"],
            key=str(uuid.uuid4()),
        ),
    )
    turn_id = str(uuid.UUID(str(submitted["turn_id"])))
    assert submitted["status"] == "queued"
    eventually(lambda: vm_state(vm["vm_id"]) == "running", timeout=300)
    eventually(
        lambda: sql(f"SELECT status FROM agent_turns WHERE id='{turn_id}'") == "completed",
        timeout=300,
    )
    result = operator(m3, dict(action="agent-result", actor_id=users["member_id"], turn_id=turn_id))
    assert result == {"status": "completed", "answer_matches": True, "reason": None}
    if otel_guest_enabled:
        # @cc [owner:ghuntley,label:verification;durability] native-guest-durable-slo-restart
        # Successful physical and ready measurements MUST use this real guest's
        # retained evidence. Restarting Marshall MUST preserve nonzero source
        # counters, buckets and lifetimes, and another scan MUST not count twice.
        eventually(lambda: durable_service_level_snapshot(m1, vm["vm_id"]) != "", timeout=120)
        before_restart = durable_service_level_snapshot(m1, vm["vm_id"])
        m1.succeed("systemctl restart marshall-m1.service")
        m1.wait_for_unit("marshall-m1.service")
        assert durable_service_level_snapshot(m1, vm["vm_id"]) == before_restart
        assert durable_service_level_snapshot(m1, vm["vm_id"]) == before_restart

    assert (
        sql(
            f"SELECT count(*) FROM agent_model_calls WHERE turn_id='{turn_id}' AND status='completed'"
        )
        == "2"
    )
    assert (
        sql(f"SELECT count(*) FROM agent_commands WHERE turn_id='{turn_id}' AND status='completed'")
        == "1"
    )
    if otel_guest_enabled:
        # @cc [owner:ghuntley,label:verification;security] otel-native-guest-path
        # The observed count MUST come from the running Firecracker guest's
        # acknowledged Lyra tool result through Audi TLS and the Rust receiver.
        # A direct host-side metric fixture would bypass the binding boundary.
        host_for(vm).wait_until_succeeds(
            "curl -fsS http://127.0.0.1:9464/metrics | "
            "awk '$1 ~ /^overalls_guest_tool_calls(_total)?\\{/ && $2+0 >= 1 {ok=1} END {exit !ok}'",
            timeout=120,
        )
        # @cc [owner:ghuntley,label:verification;security] otel-native-guest-trace
        # Query the exact trace from the acknowledged real command at the
        # selected host's disposable Tempo; no host-side OTLP injection counts.
        command_id = sql(f"SELECT id FROM agent_commands WHERE turn_id='{turn_id}'")
        assert command_id is not None
        trace_id = hashlib.sha256(
            b"overalls.lyra.tool.trace.v1:" + command_id.replace("-", "").encode()
        ).hexdigest()[:32]
        host_for(vm).wait_until_succeeds(
            "curl -fsS http://127.0.0.1:3200/api/traces/"
            + trace_id
            + " | grep -q 'lyra.tool_result'",
            timeout=120,
        )
    assert (
        sql(
            "SELECT count(*) FROM agent_audit_events WHERE turn_id="
            f"'{turn_id}' AND kind='wake_requested'"
        )
        == "1"
    )

with subtest("Standard model cannot create a forbidden child agent"):
    denied = operator(
        m2,
        dict(
            action="agent-prompt",
            actor_id=users["member_id"],
            vm_id=vm["vm_id"],
            prompt="Try child agent",
            key=str(uuid.uuid4()),
        ),
    )
    denied_turn = str(uuid.UUID(str(denied["turn_id"])))
    eventually(
        lambda: sql(f"SELECT status FROM agent_turns WHERE id='{denied_turn}'") == "failed",
        timeout=300,
    )
    result = operator(
        m3, dict(action="agent-result", actor_id=users["member_id"], turn_id=denied_turn)
    )
    assert result == {
        "status": "failed",
        "answer_matches": False,
        "reason": "capability_denied",
    }
    assert sql(f"SELECT count(*) FROM agent_commands WHERE turn_id='{denied_turn}'") == "0"
    assert (
        sql(f"SELECT count(*) FROM agent_threads WHERE parent_thread_id='{denied['thread_id']}'")
        == "0"
    )

with subtest("Rust guest fetch reaches a VM-local HTTP service with content-free audit"):
    fetched = operator(
        m2,
        dict(
            action="agent-prompt",
            actor_id=users["member_id"],
            vm_id=vm["vm_id"],
            prompt="Fetch local content",
            key=str(uuid.uuid4()),
        ),
    )
    fetched_id = str(uuid.UUID(str(fetched["turn_id"])))
    eventually(
        lambda: sql(f"SELECT status FROM agent_turns WHERE id='{fetched_id}'") == "completed",
        timeout=300,
    )
    assert (
        sql(
            f"SELECT count(*) FROM agent_commands WHERE turn_id='{fetched_id}' AND status='completed'"
        )
        == "2"
    )
    assert (
        sql(
            f"SELECT result->>'content' FROM agent_commands WHERE turn_id='{fetched_id}' AND tool='web_fetch'"
        )
        == "# Guest local content"
    )
    assert (
        sql(
            f"SELECT count(*) FROM agent_audit_events WHERE turn_id='{fetched_id}' AND row_to_json(agent_audit_events)::text LIKE '%Guest local content%'"
        )
        == "0"
    )

with subtest("Marshall web search returns every synthetic result and caches the next call"):
    first = operator(
        m2,
        dict(
            action="agent-prompt",
            actor_id=users["member_id"],
            vm_id=vm["vm_id"],
            prompt="Search example topic",
            key=str(uuid.uuid4()),
        ),
    )
    first_id = str(uuid.UUID(str(first["turn_id"])))
    eventually(
        lambda: sql(f"SELECT status FROM agent_turns WHERE id='{first_id}'") == "completed",
        timeout=300,
    )
    assert (
        sql(
            f"SELECT credits FROM agent_search_usage WHERE command_id=(SELECT id FROM agent_commands WHERE turn_id='{first_id}')"
        )
        == "3"
    )
    assert (
        sql(
            f"SELECT cache_hit FROM agent_search_usage WHERE command_id=(SELECT id FROM agent_commands WHERE turn_id='{first_id}')"
        )
        == "f"
    )
    assert (
        sql(f"SELECT result->'results'->1->>'url' FROM agent_commands WHERE turn_id='{first_id}'")
        == "https://example.org/2"
    )

    second = operator(
        m3,
        dict(
            action="agent-prompt",
            actor_id=users["member_id"],
            vm_id=vm["vm_id"],
            prompt="Search example topic",
            key=str(uuid.uuid4()),
        ),
    )
    second_id = str(uuid.UUID(str(second["turn_id"])))
    eventually(
        lambda: sql(f"SELECT status FROM agent_turns WHERE id='{second_id}'") == "completed",
        timeout=300,
    )
    assert (
        sql(
            f"SELECT credits FROM agent_search_usage WHERE command_id=(SELECT id FROM agent_commands WHERE turn_id='{second_id}')"
        )
        == "0"
    )
    assert (
        sql(
            f"SELECT cache_hit FROM agent_search_usage WHERE command_id=(SELECT id FROM agent_commands WHERE turn_id='{second_id}')"
        )
        == "t"
    )
    assert (
        sql(
            f"SELECT count(*) FROM agent_audit_events WHERE turn_id='{second_id}' AND kind='tool_finished'"
        )
        == "1"
    )
