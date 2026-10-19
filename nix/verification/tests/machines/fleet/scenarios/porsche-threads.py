# @cc [owner:ghuntley,label:verification;security] fleet-porsche-threads-journey
# Mila's thread, web and watch commands MUST traverse native OpenSSH, the
# packaged Porsche gateway and verified Marshall control into the Threads and
# Ingress domains. Prompt text MUST travel only on stdin and MUST NOT appear
# in receipts; a watch MUST open through Marshall's subscription authority and
# renew on heartbeat (revocation is covered by the BEAM transport test). Runs after
# porsche.py's key approval and authorized dispatch, reusing its client keys,
# known_hosts and porsche_arguments helper.
from typing import TypedDict


class ThreadsRun(TypedDict):
    returncode: int
    stdout: str


def porsche_threads_object(value: object) -> dict[str, object] | None:
    """Narrows parsed JSON to a string-keyed object, or None for any other value."""
    if not isinstance(value, dict):
        return None
    narrowed: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            return None
        narrowed[key] = item
    return narrowed


def porsche_threads_run(command: str, stdin: str = "", timeout: int = 120) -> ThreadsRun:
    """Runs one exec as the owner, keeping private output inside the client VM."""
    arguments = porsche_arguments(command)
    # A bounded stream (watch) ends by timeout; its partial stdout is kept.
    program = (
        "import subprocess,json\n"
        "try:\n"
        "    r=subprocess.run("
        + repr(arguments)
        + ",input="
        + repr(stdin)
        + ",capture_output=True,text=True,timeout="
        + repr(timeout)
        + ")\n"
        "    out={'returncode': r.returncode, 'stdout': r.stdout}\n"
        "except subprocess.TimeoutExpired as e:\n"
        "    data=e.stdout or b''\n"
        "    data=data.decode() if isinstance(data, bytes) else data\n"
        "    out={'returncode': -1, 'stdout': data}\n"
        "print(json.dumps(out))"
    )
    raw = porsche_threads_object(
        json.loads(
            client.succeed(
                "sudo -u tester python3 -c " + shlex.quote(program), timeout=timeout + 30
            )
        )
    )
    if raw is None:
        raise AssertionError("invalid Porsche run result")
    returncode = raw.get("returncode")
    stdout = raw.get("stdout")
    if not isinstance(returncode, int) or not isinstance(stdout, str):
        raise AssertionError("invalid Porsche run fields")
    return ThreadsRun(returncode=returncode, stdout=stdout)


def porsche_threads_json(command: str, stdin: str = "") -> dict[str, object]:
    run = porsche_threads_run(command, stdin)
    value = porsche_threads_object(json.loads(run["stdout"]))
    if value is None:
        raise AssertionError("invalid Porsche JSON document")
    assert run["returncode"] == 0, "Porsche thread command failed: " + str(value.get("error"))
    return value


def porsche_threads_result(value: dict[str, object]) -> dict[str, object]:
    result = porsche_threads_object(value.get("result"))
    if result is None:
        raise AssertionError("missing Porsche result")
    return result


with subtest("Porsche thread, web and watch commands drive Marshall domains"):
    thread_id = str(
        operator(
            m1,
            dict(
                action="thread-create",
                owner_id=users["owner_id"],
                image_id=users["image_id"],
                key=str(uuid.uuid4()),
            ),
        )["thread_id"]
    )
    eventually(
        lambda: sql(f"SELECT status FROM threads WHERE id='{thread_id}'") == "ready",
        timeout=600,
    )
    # This fleet has no model provider, so the objective's first turn stays
    # active; a same-mode prompt queues behind it rather than being refused.

    listed = porsche_threads_result(porsche_threads_json("thread ls"))
    items = listed.get("items")
    assert isinstance(items, list) and any(
        (porsche_threads_object(item) or {}).get("id") == thread_id for item in items
    )

    secret_prompt = "Report the hostname for porsche-threads " + str(uuid.uuid4())
    prompted = porsche_threads_json(
        f"thread prompt {thread_id} - --request-id {uuid.uuid4()}", secret_prompt + "\n"
    )
    assert prompted.get("status") == "succeeded"
    assert secret_prompt not in json.dumps(prompted)
    assert (
        sql(
            "SELECT count(*) FROM ssh_requests WHERE command::text LIKE "
            + "'%"
            + secret_prompt.replace("'", "''")
            + "%'"
        )
        == "0"
    )
    assert (
        sql(
            "SELECT count(*) FROM ssh_requests WHERE ssh_key_id IS NOT NULL "
            "AND command->>'command'='thread prompt'"
        )
        == "1"
    )

    shown = porsche_threads_result(porsche_threads_json(f"thread show {thread_id}"))
    assert shown.get("id") == thread_id
    marked = porsche_threads_result(
        porsche_threads_json(f"thread read {thread_id} 1 --request-id {uuid.uuid4()}")
    )
    assert isinstance(marked.get("read_sequence"), int)

    oversized = porsche_threads_run(f"thread prompt {thread_id} -", "a" * 65_537)
    assert oversized["returncode"] == 2

    machine_id = sql(f"SELECT machine_id FROM threads WHERE id='{thread_id}'")
    web = porsche_threads_result(porsche_threads_json(f"web show {machine_id}"))
    revision = web.get("policy_revision")
    assert isinstance(revision, int)
    changed = porsche_threads_result(
        porsche_threads_json(f"web set {machine_id} --port 8080 --request-id {uuid.uuid4()}")
    )
    assert changed.get("policy_revision") == revision + 1
    stale = porsche_threads_run(
        f"web set {machine_id} --private --revision {revision} --request-id {uuid.uuid4()}"
    )
    assert stale["returncode"] == 2 and "revision_conflict" in stale["stdout"]

    # A watch never ends on its own; the bounded run sees the opening line and
    # at least one heartbeat before its timeout.
    watching = porsche_threads_run(f"watch --thread {thread_id}", timeout=40)
    assert watching["returncode"] == -1, "watch ended before its bound"
    lines = [json.loads(line) for line in watching["stdout"].splitlines() if line]
    assert lines and lines[0].get("event") == "watching"
    assert lines[0].get("threads") == [thread_id]
    assert any(line.get("event") == "heartbeat" for line in lines)
