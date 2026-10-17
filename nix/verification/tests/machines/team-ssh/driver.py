"""@cc [owner:ghuntley,label:verification] teams-native-receipt-inventories
Refused commands and historical receipt replays MUST preserve complete durable
team, membership, transfer, audit and version rows. Fresh safe creator retries
may add only their SSH request receipt. All tested actors MUST remain ordinary.
"""

import json
import shlex
import traceback
import uuid


def json_object(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError("Expected JSON object")
    result: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            raise ValueError("Expected JSON object key")
        result[key] = item
    return result


def decode_reply(output: str, actual: int, expected: int) -> dict[str, object]:
    """@cc [owner:ghuntley,label:security] teams-ssh-response-failure-custody
    Unexpected SSH output MAY contain an onboarding bearer URL. Parsing and
    status failures MUST expose only a fixed diagnostic without response maps,
    raw bytes or chained exceptions. Returned fields MUST be validated.
    """
    try:
        if actual != expected:
            raise ValueError("Unexpected exit status")
        decoded: object = json.loads(output)
        raw = json_object(decoded)
        if raw.get("version") != 1:
            raise ValueError("Unexpected reply version")
        if expected == 0:
            if raw.get("status") != "succeeded" or raw.get("operation_id") is not None:
                raise ValueError("Unexpected metadata result")
            fields = json_object(raw.get("result"))
            safe_fields: dict[str, object] = {}
            allowed = {
                "id",
                "name",
                "email",
                "transfer_id",
                "state",
                "team_id",
                "user_id",
                "role",
                "guest_username",
                "public_key",
            }
            for key, value in fields.items():
                if key not in allowed or not isinstance(value, str):
                    raise ValueError("Unexpected result field")
                safe_fields[key] = value
            return {
                "version": 1,
                "status": "succeeded",
                "request_id": raw.get("request_id"),
                "result": safe_fields,
            }
        reason = raw.get("error")
        if raw.get("status") != "error" or reason not in (
            "conflict",
            "not_found",
            "forbidden",
            "invalid_request",
            "idempotency_conflict",
        ):
            raise ValueError("Unexpected refusal")
        return {"version": 1, "status": "error", "error": reason}
    except Exception:
        raise RuntimeError("Teams SSH reply validation failed") from None


def check_failure_custody() -> None:
    """@cc [owner:ghuntley,label:verification] teams-ssh-error-redaction
    A synthetic onboarding-shaped response MUST fail without its bearer URL
    appearing in formatted diagnostics, including a mismatched exit status.
    """
    sensitive = "porsche_approval_synthetic_private_marker"
    payload = json.dumps(
        {
            "version": 1,
            "status": "approval_required",
            "approval_url": "https://control.example.test/ssh/approve/" + sensitive,
        }
    )
    for actual in [0, 3]:
        try:
            decode_reply(payload, actual, 0)
        except RuntimeError as error:
            rendered = "".join(traceback.format_exception(error))
            if sensitive in rendered or "https://control.example.test/ssh/approve/" in rendered:
                raise AssertionError("Teams SSH diagnostic custody failed") from None
        else:
            raise AssertionError("Unexpected onboarding success")


check_failure_custody()

start_all()
control.wait_for_unit("postgresql-setup.service")
control.succeed("systemctl start overalls-test-migrate.service")
control.wait_until_succeeds(
    "curl --fail --silent --cacert /run/overalls-test/ca.crt https://localhost:4443/health/ready",
    timeout=120,
)
client.wait_for_unit("multi-user.target")
client.succeed("sudo -u tester install -d -m 700 /home/tester/.ssh")
for identity in ["owner", "target", "foreign"]:
    client.succeed("sudo -u tester ssh-keygen -q -t ed25519 -N '' -f /home/tester/.ssh/" + identity)
    public = client.succeed("cat /home/tester/.ssh/" + identity + ".pub").strip()
    control.succeed(
        "printf '%s\\n' " + shlex.quote(public) + " >/run/overalls-test/" + identity + ".pub"
    )
control.succeed("systemctl start team-ssh-seed.service")
control.succeed("systemctl start porsche.service")
control.wait_for_open_port(22)
# The trusted operator obtains the fixture CA directly, never from ssh-keyscan.
key = control.succeed("ssh-keygen -y -f /run/overalls-test/ssh-host-ca").split()
client.succeed(
    "printf '%s\\n' "
    + shlex.quote("@cert-authority control.example.test " + " ".join(key[:2]))
    + " >/home/tester/.ssh/known_hosts"
)
client.succeed(
    "chown tester:users /home/tester/.ssh/known_hosts; chmod 600 /home/tester/.ssh/known_hosts"
)


def sql(query: str) -> str:
    return control.succeed(
        "sudo -u postgres psql --no-psqlrc -d marshall -At -v ON_ERROR_STOP=1 -c "
        + shlex.quote(query)
    ).strip()


def inventory(include_requests: bool = True) -> str:
    tables = [
        "teams",
        "team_members",
        "team_transfers",
        "teams_versions",
        "team_members_versions",
        "team_transfers_versions",
        "account_admin_events",
    ]
    if include_requests:
        tables.append("ssh_requests")
    return "\n".join(
        sql("SELECT row_to_json(t) FROM " + table + " t ORDER BY id") for table in tables
    )


def ordinary() -> None:
    assert (
        sql(
            "SELECT count(*), count(*) FILTER (WHERE administrator) FROM users WHERE email IN ('team-owner@example.test', 'team-target@example.test', 'team-foreign@example.test')"
        )
        == "3|0"
    )


def command(identity: str, value: str, status: int = 0) -> dict[str, object]:
    ssh = (
        "sudo -u tester ssh -T -o BatchMode=yes -o StrictHostKeyChecking=yes -o HostKeyAlgorithms=ssh-ed25519-cert-v01@openssh.com -o IdentitiesOnly=yes -o ConnectTimeout=5 -i /home/tester/.ssh/"
        + identity
        + " untrusted@control.example.test "
        + shlex.quote(value + " --json")
    )
    try:
        actual, output = client.execute(ssh)
        return decode_reply(output, actual, status)
    except Exception:
        raise RuntimeError("Teams SSH command failed") from None


def field(value: dict[str, object], key: str) -> str:
    """@cc [owner:ghuntley,label:verification;security] teams-native-reference-validation
    Team and transfer IDs MUST be canonical UUIDs before entering observed SQL
    or subsequent commands. Malformed responses MUST fail without raw values.
    """
    try:
        result = json_object(value.get("result"))
        selected: object = result.get(key)
        if not isinstance(selected, str):
            raise ValueError("Expected result string")
        if key in ("id", "transfer_id") and str(uuid.UUID(selected)) != selected:
            raise ValueError("Expected canonical UUID")
        return selected
    except Exception:
        raise RuntimeError("Teams SSH result validation failed") from None


def refused(identity: str, value: str, status: int, reason: str) -> None:
    before = inventory()
    response = command(identity, value, status)
    assert response.get("error") == reason
    assert inventory() == before


ordinary()
with subtest("ordinary accounts create and retry teams through packaged Porsche"):
    for identity in ["owner", "target", "foreign"]:
        assert field(command(identity, "whoami"), "email") == "team-" + identity + "@example.test"
    ordinary()
    original = command("owner", "team create native-team --request-id original")
    team = field(original, "id")
    assert original.get("status") == "succeeded"
    before = inventory()
    assert command("owner", "team create native-team --request-id original") == original
    assert command("owner", "request show original") == original
    assert inventory() == before
    before = inventory(include_requests=False)
    assert field(command("owner", "team create native-team --request-id safe-retry"), "id") == team
    assert inventory(include_requests=False) == before
    assert (
        sql("SELECT count(*) FROM teams_versions WHERE version_source_id = '" + team + "'") == "1"
    )
    assert sql("SELECT count(*) FROM account_admin_events WHERE target_id = '" + team + "'") == "2"
    refused("owner", "team create Invalid-name --request-id bad-name", 2, "invalid_request")
    refused("foreign", "team create native-team --request-id collision", 2, "conflict")
    refused("owner", "team create changed-name --request-id original", 2, "idempotency_conflict")
    refused("owner", "team show missing-team", 2, "not_found")
    refused(
        "foreign", "team member add native-team team-target@example.test member", 3, "forbidden"
    )

with subtest("consenting target transfers ownership and stale users remain refused"):
    command("owner", "team member add native-team team-target@example.test member --request-id add")
    declined = field(
        command(
            "owner",
            "team transfer offer native-team team-target@example.test --request-id decline-offer",
        ),
        "transfer_id",
    )
    command("target", "team transfer decline " + declined + " --request-id decline")
    refused("target", "team transfer decline " + declined, 2, "conflict")
    refused("owner", "team transfer accept 00000000-0000-4000-8000-000000000001", 2, "not_found")
    offer = command(
        "owner", "team transfer offer native-team team-target@example.test --request-id offer"
    )
    transfer = field(offer, "transfer_id")
    refused("owner", "team transfer offer native-team team-target@example.test", 2, "conflict")
    refused("foreign", "team transfer accept " + transfer, 3, "forbidden")
    command("target", "team transfer accept " + transfer + " --request-id accept")
    command("target", "team member remove native-team team-owner@example.test --request-id remove")
    refused("owner", "team show native-team", 3, "forbidden")
    refused("owner", "team create native-team --request-id after-transfer", 2, "conflict")
    refused("target", "team create native-team --request-id new-owner-create", 2, "conflict")
    before = inventory()
    assert command("owner", "team create native-team --request-id original") == original
    assert command("owner", "request show original") == original
    assert inventory() == before
    assert (
        sql(
            "SELECT u.email || ':' || m.role FROM team_members m JOIN users u ON u.id = m.user_id WHERE m.team_id = '"
            + team
            + "' AND m.archived_at IS NULL"
        )
        == "team-target@example.test:owner"
    )
    recovery = command("owner", "team create native-recovery --request-id recovery")
    assert field(recovery, "id") != team
    assert sql("SELECT count(*) FROM ssh_requests") == "9"
    ordinary()
