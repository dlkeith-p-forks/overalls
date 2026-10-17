import json
import time

start_all()
mirror.wait_for_unit("nginx.service")
mirror.wait_for_unit("enrico.service")
mirror.wait_for_unit("opentelemetry-collector.service")
mirror.wait_until_succeeds(
    "curl --fail --silent --unix-socket /run/enrico/status.sock http://enrico/health/ready | jq -e '.ready == true'"
)
mirror.succeed("git init -q /tmp/source")
mirror.succeed("sh -c 'printf first > /tmp/source/hello.txt'")
mirror.succeed("git -C /tmp/source add hello.txt")
mirror.succeed(
    "git -C /tmp/source -c user.email=test@example.test -c user.name=Test commit -qm first"
)
mirror.succeed("mkdir -p /var/lib/git-fixture/NixOS")
mirror.succeed("git clone -q --bare /tmp/source /var/lib/git-fixture/NixOS/nixpkgs.git")
mirror.succeed("git --git-dir=/var/lib/git-fixture/NixOS/nixpkgs.git update-server-info")
mirror.succeed(
    "GIT_SSL_CAINFO=/etc/enrico-test-ca.pem git -c http.followRedirects=false clone --mirror https://github.com/NixOS/nixpkgs.git /tmp/probe.git"
)

base = "https://enrico.fleet.internal:5445/v1/repos/11111111-1111-4111-8111-111111111111"
curl = (
    "curl --fail --silent --show-error --noproxy '*' "
    "--cacert /etc/enrico-test-ca.pem "
    "-H 'authorization: Bearer 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' "
)

with subtest("unauthorized request cannot read cache"):
    code = mirror.succeed(
        "curl --silent --noproxy '*' --cacert /etc/enrico-test-ca.pem "
        "-o /dev/null -w '%{http_code}' " + base + "/git/tree"
    ).strip()
    assert code == "401", code
    mirror.succeed(
        "test $(curl --silent --output /dev/null --write-out '%{http_code}' "
        "--unix-socket /run/enrico/status.sock http://enrico/slo) = 404"
    )


def refresh(attempt: str) -> dict[str, object]:
    payload = json.dumps({"attempt_id": attempt, "owner": "NixOS", "repo": "nixpkgs"})
    mirror.succeed(
        curl + "-H 'content-type: application/json' --data '" + payload + "' " + base + "/refresh"
    )
    for _ in range(60):
        result = json.loads(mirror.succeed(curl + base + "/attempts/" + attempt))
        status = result["status"]
        if isinstance(status, dict) and status.get("state") == "succeeded":
            return status
        if status == "failed":
            raise AssertionError("refresh failed")
        time.sleep(1)
    raise AssertionError("refresh timeout")


def nonnegative(value: object) -> int:
    if isinstance(value, bool) or not isinstance(value, int) or value < 0:
        raise AssertionError("invalid SLO counter")
    return value


def object_fields(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise AssertionError("invalid SLO object")
    fields: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            raise AssertionError("invalid SLO key")
        fields[key] = item
    return fields


def sample_time() -> int:
    return nonnegative(
        json.loads(
            mirror.succeed(
                "jq -c .sampled_at_unix_nano /run/overalls-request-enrico-source/slo.json"
            )
        )
    )


def slo_history() -> tuple[str, int, int, int, int, int]:
    """@cc [owner:ghuntley,label:verification] enrico-native-durable-history
    Restart comparisons MUST use validated durable source identity and terminal
    counters; the removed in-memory endpoint MUST NOT substitute for custody.
    """
    raw = object_fields(
        json.loads(mirror.succeed("cat /run/overalls-request-enrico-source/slo.json"))
    )
    incarnation: object = raw.get("incarnation")
    duration = object_fields(raw.get("duration"))
    if raw.get("service") != "enrico" or not isinstance(incarnation, str):
        raise AssertionError("invalid SLO identity or histogram")
    requests = nonnegative(raw.get("requests"))
    successes = nonnegative(raw.get("successes"))
    failures = nonnegative(raw.get("failures"))
    count = nonnegative(duration.get("count"))
    assert requests == successes + failures and count <= requests
    return (
        incarnation,
        nonnegative(raw.get("started_at_unix_nano")),
        requests,
        successes,
        failures,
        count,
    )


with subtest("invalid source labels are refused without mirror state"):
    bad = json.dumps(
        {
            "attempt_id": "66666666-6666-4666-8666-666666666666",
            "owner": "../marshall",
            "repo": "overalls",
        }
    )
    refused = mirror.succeed(
        "curl --silent --noproxy '*' --cacert /etc/enrico-test-ca.pem "
        "-H 'authorization: Bearer 0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef' "
        "-H 'content-type: application/json' -o /dev/null -w '%{http_code}' --data '"
        + bad
        + "' "
        + base
        + "/refresh"
    ).strip()
    assert refused == "400", refused
    missing = json.loads(
        mirror.succeed(curl + base + "/attempts/66666666-6666-4666-8666-666666666666")
    )
    assert missing["status"] == "missing", missing
    mirror.fail("test -d /var/lib/enrico/11111111-1111-4111-8111-111111111111.git")


with subtest("clone and read full Git mirror"):
    result = refresh("22222222-2222-4222-8222-222222222222")
    assert isinstance(result["head"], str) and len(result["head"]) == 40
    tree = json.loads(mirror.succeed(curl + "'" + base + "/git/tree?ref=HEAD'"))
    import base64

    assert b"hello.txt" in base64.b64decode(tree["data_base64"])
    assert mirror.succeed(curl + "'" + base + "/git/blob?ref=HEAD&path=hello.txt'") == "first"

with subtest("Rust exporter delivers Enrico-owned terminal outcomes to the isolated collector"):
    mirror.wait_for_unit("overalls-request-enrico-exporter.service")
    mirror.wait_until_succeeds(
        'jq -e \'.service == "enrico" and .requests == 1 and .successes == 1 '
        "and .failures == 0 and .duration.count == 1 and "
        "([.duration.bucket_counts[]] | add) == 1' /run/overalls-request-enrico-source/slo.json"
    )
    mirror.wait_until_succeeds(
        "curl -fsS http://127.0.0.1:9464/metrics | "
        'grep -E \'overalls_outer_enrico_requests_total\\{[^}]*overalls_telemetry_origin="application"[^}]*service_name="enrico"[^}]*\\} 1\'',
        timeout=45,
    )
    mirror.succeed(
        "code=$(runuser -u enrico -- curl --silent --output /dev/null "
        "--write-out '%{http_code}' --unix-socket "
        "/run/overalls-otel-enrico/collector.sock http://localhost/v1/metrics || true); "
        'test "$code" = 000'
    )

with subtest("recorder SIGKILL preserves completed refresh with the real producer alive"):
    recorded = slo_history()
    producer_pid = mirror.succeed("systemctl show enrico.service -p MainPID --value").strip()
    sample = sample_time()
    mirror.succeed(
        "systemctl kill --signal=SIGKILL --kill-whom=main overalls-request-enrico.service"
    )
    mirror.wait_for_unit("overalls-request-enrico.service")
    mirror.wait_until_succeeds(
        "jq -e '.sampled_at_unix_nano > "
        + str(sample)
        + "' /run/overalls-request-enrico-source/slo.json"
    )
    assert (
        mirror.succeed("systemctl show enrico.service -p MainPID --value").strip() == producer_pid
    )
    assert slo_history() == recorded
    assert mirror.succeed(curl + "'" + base + "/git/blob?ref=HEAD&path=hello.txt'") == "first"

with subtest("clean Enrico restart preserves durable identity and terminal outcomes"):
    recorded = slo_history()
    sample = sample_time()
    mirror.succeed("systemctl restart enrico.service")
    mirror.wait_for_unit("enrico.service")
    mirror.wait_until_succeeds(
        "curl -fsS --unix-socket /run/enrico/status.sock http://enrico/health/ready | jq -e '.ready == true'"
    )
    mirror.wait_until_succeeds(
        "jq -e '.sampled_at_unix_nano > "
        + str(sample)
        + "' /run/overalls-request-enrico-source/slo.json"
    )
    assert slo_history() == recorded
    assert mirror.succeed(curl + "'" + base + "/git/blob?ref=HEAD&path=hello.txt'") == "first"

with subtest("update the mirror"):
    mirror.succeed("sh -c 'printf second > /tmp/source/hello.txt'")
    mirror.succeed("git -C /tmp/source add hello.txt")
    mirror.succeed(
        "git -C /tmp/source -c user.email=test@example.test -c user.name=Test commit -qm second"
    )
    mirror.succeed("git -C /tmp/source push -q /var/lib/git-fixture/NixOS/nixpkgs.git HEAD")
    mirror.succeed("git --git-dir=/var/lib/git-fixture/NixOS/nixpkgs.git update-server-info")
    second = refresh("33333333-3333-4333-8333-333333333333")
    second_head = second["head"]
    assert isinstance(second_head, str)
    assert mirror.succeed(curl + "'" + base + "/git/blob?ref=HEAD&path=hello.txt'") == "second"

with subtest("force-push keeps the previously published commit after Git pruning"):
    branch = mirror.succeed("git -C /tmp/source branch --show-current").strip()
    mirror.succeed("git -C /tmp/source checkout -q --orphan rewritten")
    mirror.succeed("sh -c 'printf third > /tmp/source/hello.txt'")
    mirror.succeed("git -C /tmp/source add hello.txt")
    mirror.succeed(
        "git -C /tmp/source -c user.email=test@example.test -c user.name=Test commit -qm third"
    )
    mirror.succeed(
        "git -C /tmp/source push -q --force /var/lib/git-fixture/NixOS/nixpkgs.git "
        + "HEAD:refs/heads/"
        + branch
    )
    mirror.succeed("git --git-dir=/var/lib/git-fixture/NixOS/nixpkgs.git update-server-info")
    third = refresh("55555555-5555-4555-8555-555555555555")
    third_head = third["head"]
    assert isinstance(third_head, str)
    mirror.succeed(
        "git --git-dir=/var/lib/enrico/11111111-1111-4111-8111-111111111111.git gc --prune=now"
    )
    assert (
        mirror.succeed(curl + "'" + base + "/git/blob?ref=" + second_head + "&path=hello.txt'")
        == "second"
    )
    assert mirror.succeed(curl + "'" + base + "/git/blob?ref=HEAD&path=hello.txt'") == "third"


with subtest("a repeated attempt returns its recorded result without a new fetch"):
    again = json.loads(
        mirror.succeed(
            curl
            + "-H 'content-type: application/json' --data '"
            + json.dumps(
                {
                    "attempt_id": "55555555-5555-4555-8555-555555555555",
                    "owner": "NixOS",
                    "repo": "nixpkgs",
                }
            )
            + "' "
            + base
            + "/refresh"
        )
    )
    replayed = again["status"]
    assert isinstance(replayed, dict) and replayed.get("state") == "succeeded", again
    assert replayed.get("head") == third_head, again
    mirror.succeed(
        "jq -e '.requests == 3 and .successes == 3 and .failures == 0' "
        "/run/overalls-request-enrico-source/slo.json"
    )

with subtest("preserve published cache after source outage"):
    mirror.succeed("systemctl stop nginx.service")
    failure = json.dumps(
        {"attempt_id": "44444444-4444-4444-8444-444444444444", "owner": "NixOS", "repo": "nixpkgs"}
    )
    mirror.succeed(
        curl + "-H 'content-type: application/json' --data '" + failure + "' " + base + "/refresh"
    )
    mirror.wait_until_succeeds(
        curl
        + base
        + "/attempts/44444444-4444-4444-8444-444444444444 | jq -e '.status == \"failed\"'",
        timeout=30,
    )
    assert mirror.succeed(curl + "'" + base + "/git/blob?ref=HEAD&path=hello.txt'") == "third"
    mirror.succeed(
        "jq -e '.requests == 4 and .successes == 3 and .failures == 1' "
        "/run/overalls-request-enrico-source/slo.json"
    )

with subtest("refresh recovers after the source returns"):
    mirror.succeed("systemctl start nginx.service")
    mirror.wait_for_unit("nginx.service")
    mirror.succeed("sh -c 'printf fourth > /tmp/source/hello.txt'")
    mirror.succeed("git -C /tmp/source add hello.txt")
    mirror.succeed(
        "git -C /tmp/source -c user.email=test@example.test -c user.name=Test commit -qm fourth"
    )
    mirror.succeed(
        "git -C /tmp/source push -q --force /var/lib/git-fixture/NixOS/nixpkgs.git "
        + "HEAD:refs/heads/"
        + branch
    )
    mirror.succeed("git --git-dir=/var/lib/git-fixture/NixOS/nixpkgs.git update-server-info")
    fourth = refresh("77777777-7777-4777-8777-777777777777")
    fourth_head = fourth["head"]
    assert isinstance(fourth_head, str)
    assert fourth_head != third_head
    assert mirror.succeed(curl + "'" + base + "/git/blob?ref=HEAD&path=hello.txt'") == "fourth"

with subtest("producer SIGKILL settles blocked admitted refresh without inventing duration"):
    # Pause every nginx worker to block the real verified-TLS Git fetch.
    recorded = slo_history()
    mirror.succeed("systemctl kill --signal=SIGSTOP --kill-whom=all nginx.service")
    try:
        payload = json.dumps(
            {
                "attempt_id": "88888888-8888-4888-8888-888888888888",
                "owner": "NixOS",
                "repo": "nixpkgs",
            }
        )
        mirror.succeed(
            curl
            + "-H 'content-type: application/json' --data '"
            + payload
            + "' "
            + base
            + "/refresh"
        )
        mirror.wait_until_succeeds(
            "jq -e '(.pending | length) == 1' /var/lib/overalls-request-enrico/state.json",
            timeout=30,
        )
        mirror.succeed("systemctl kill --signal=SIGKILL --kill-whom=all enrico.service")
    finally:
        mirror.succeed("systemctl kill --signal=SIGCONT --kill-whom=all nginx.service")
    mirror.wait_for_unit("enrico.service")
    mirror.wait_until_succeeds(
        "jq -e '.requests == "
        + str(recorded[2] + 1)
        + " and .failures == "
        + str(recorded[4] + 1)
        + "' /run/overalls-request-enrico-source/slo.json",
        timeout=45,
    )
    expected = (
        recorded[0],
        recorded[1],
        recorded[2] + 1,
        recorded[3],
        recorded[4] + 1,
        recorded[5],
    )
    assert slo_history() == expected
    mirror.succeed("jq -e '(.pending | length) == 0' /var/lib/overalls-request-enrico/state.json")
    assert mirror.succeed(curl + "'" + base + "/git/blob?ref=HEAD&path=hello.txt'") == "fourth"
    time.sleep(2)
    assert slo_history() == expected
