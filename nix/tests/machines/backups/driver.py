"""Real ZFS, Restic over TLS S3, remote PostgreSQL and isolated logical restore."""

import json
import shlex
import time

start_all()
database.wait_for_unit("postgresql.service")
storage.wait_for_unit("multi-user.target")
storage.wait_for_unit("minio.service")
storage.wait_for_unit("nginx.service")
storage.wait_for_open_port(9000)
storage.succeed("zpool create -f -O mountpoint=/persistent -O compression=lz4 backupdata /dev/vdb")
storage.succeed("install -d -m 0700 /persistent/secrets")
keyring_script = (
    "import base64,json,pathlib,secrets; "
    "p=pathlib.Path('/persistent/secrets/cloak-keyring.enc'); "
    "p.write_text(json.dumps([{'id':'backup-fixture','key':base64.b64encode(secrets.token_bytes(32)).decode()}])); "
    "p.chmod(0o600)"
)
storage.succeed("python3 -c " + shlex.quote(keyring_script))
storage.succeed("install -d -m 0700 /run/backup-fixture")
storage.succeed("printf '%s' 'fixture-restic-password' > /run/backup-fixture/password")
storage.succeed(
    "printf '%s\\n' 'AWS_ACCESS_KEY_ID=fixture-access' 'AWS_SECRET_ACCESS_KEY=fixture-secret-password' > /run/backup-fixture/s3.env"
)
storage.succeed(
    "printf '%s\\n' 'DATABASE_URL=ecto://marshall:fixture-db-password@db.test:6543/control' "
    "'MARSHALL_DB_TLS=verify' 'MARSHALL_DB_CA_CERTFILE=/etc/ssl/certs/ca-certificates.crt' "
    "> /run/backup-fixture/marshall.env"
)
signing_script = (
    "import pathlib,secrets; p=pathlib.Path('/run/backup-fixture/marshall.env'); "
    "f=p.open('a'); f.write('SECRET_KEY_BASE='+secrets.token_hex(48)+'\\n'); "
    "f.write('TOKEN_SIGNING_SECRET='+secrets.token_hex(48)+'\\n'); f.close()"
)
storage.succeed("python3 -c " + shlex.quote(signing_script))
storage.succeed("chmod 0600 /run/backup-fixture/*")
storage.succeed(
    "mc alias set fixture http://127.0.0.1:9000 fixture-access fixture-secret-password; mc mb fixture/backups"
)
storage.succeed(
    "curl --fail --cacert /etc/ssl/certs/ca-certificates.crt https://s3.test/minio/health/live"
)
probe, diagnostic = storage.execute(
    "AWS_ACCESS_KEY_ID=fixture-access AWS_SECRET_ACCESS_KEY=fixture-secret-password SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt RESTIC_PASSWORD_FILE=/run/backup-fixture/password timeout 35 restic -r s3:https://s3.test/backups/hosts/storage cat config",
    timeout=40,
)
assert probe == 10, (probe, diagnostic)
storage.succeed("printf '%s\\n' node-recovery > /persistent/state.txt")
storage.succeed("printf '%s\\n' exclude-me > /persistent/disposable.txt")


def write_cloak_request(action: str, keyring: str, digest: str) -> None:
    request = json.dumps({"action": action, "keyring": keyring, "digest": digest})
    storage.succeed(
        "printf '%s' "
        + shlex.quote(request)
        + " > /run/backup-fixture/cloak-request.json && chmod 0600 /run/backup-fixture/cloak-request.json"
    )


with subtest("Marshall creates real encrypted wildcard custody before backup"):
    write_cloak_request(
        "create",
        "/persistent/secrets/cloak-keyring.enc",
        "/persistent/secrets/cloak-digest.json",
    )
    storage.succeed("systemctl start backup-cloak-probe.service", timeout=180)

with subtest("module jitter reaches actual systemd timers"):
    timer = storage.succeed("systemctl cat overalls-backup.timer")
    assert "RandomizedDelaySec=300" in timer
    assert "FixedRandomDelay=true" in timer

with subtest("host and configured remote database produce a complete recovery point"):
    result, _ = storage.execute("systemctl start overalls-backup.service", timeout=180)
    status = json.loads(storage.succeed("cat /var/lib/overalls-backups/status.json"))
    assert result == 0 and status["state"] == "healthy", status
    first_success = status["last_success_at"]
    storage.succeed('test -z "$(zfs list -H -t snapshot -o name)"')
    points = json.loads(storage.succeed("overalls-backup list"))
    assert len(points) == 1
    identity = points[0]["id"]
    manifest = json.loads(
        storage.succeed("overalls-backup inspect --snapshot " + shlex.quote(identity))
    )
    assert {row["kind"] for row in manifest["components"]} == {"host-state", "postgres"}
    manifest_components = {row["snapshot_id"] for row in manifest["components"]}

with subtest("operator SIGKILL during a real upload reconciles through the cleanup unit"):
    # Widen the upload window with a payload that stays below quota checks.
    storage.succeed("dd if=/dev/urandom of=/persistent/large.bin bs=1M count=48")
    storage.succeed("systemctl start --no-block overalls-backup.service")
    storage.wait_until_succeeds(
        "test -f /var/lib/overalls-backups/run.json "
        '&& test "$(jq -r .phase /var/lib/overalls-backups/run.json)" = capturing',
        timeout=60,
    )
    # The host ZFS snapshot appears when the host capture leg starts; upload of
    # the 48 MiB payload then streams for several seconds at the 8 MiB/s limit
    # (the database leg is journaled before it). Kill inside that window.
    storage.wait_until_succeeds('test -n "$(zfs list -H -t snapshot -o name)"', timeout=60)
    time.sleep(1.5)
    storage.succeed("systemctl kill --signal=KILL overalls-backup.service")
    storage.wait_until_succeeds("systemctl is-failed -q overalls-backup.service", timeout=30)
    no_restic = "python3 -c " + shlex.quote(
        "import glob; "
        "assert all('restic' not in open(c).read() for c in glob.glob('/proc/[0-9]*/comm'))"
    )
    storage.wait_until_succeeds(no_restic, timeout=30)
    journal = json.loads(storage.succeed("cat /var/lib/overalls-backups/run.json"))
    assert journal["phase"] == "capturing" and journal["components"], journal
    status = json.loads(storage.succeed("cat /var/lib/overalls-backups/status.json"))
    assert status["state"] == "running"
    # The orphaned component upload must never be referenced by a manifest.
    recovered = storage.succeed(
        "AWS_ACCESS_KEY_ID=fixture-access AWS_SECRET_ACCESS_KEY=fixture-secret-password "
        "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt "
        "RESTIC_PASSWORD_FILE=/run/backup-fixture/password "
        "restic -r s3:https://s3.test/backups/hosts/storage snapshots --json"
    )
    killed_upload = [
        row["id"]
        for row in json.loads(recovered)
        if "postgres" in row.get("tags", []) and row["id"] not in manifest_components
    ]
    assert len(killed_upload) == 1, killed_upload
    killed_upload = killed_upload[0]
    # The boot/five-minute cleanup unit reconciles; a retry is a stable no-op.
    storage.succeed("systemctl start overalls-backup-cleanup.service", timeout=60)
    status = json.loads(storage.succeed("cat /var/lib/overalls-backups/status.json"))
    assert status["state"] == "failed" and status["failure"] == "interrupted", status
    assert status["last_success_at"] == first_success
    journal = json.loads(storage.succeed("cat /var/lib/overalls-backups/run.json"))
    assert journal["phase"] == "failed" and journal["failures"] == ["interrupted"], journal
    storage.succeed('test -z "$(zfs list -H -t snapshot -o name)"')
    storage.succeed("systemctl start overalls-backup-cleanup.service", timeout=60)
    journal_retry = json.loads(storage.succeed("cat /var/lib/overalls-backups/run.json"))
    assert journal_retry == journal
    storage.succeed("rm /persistent/large.bin")

with subtest("interrupted writer lock refuses closed retention until operator unlock"):
    # The SIGKILLed upload left the writer's restic backend lock. Reader and
    # non-exclusive append operations still work; exclusive retention refuses
    # without touching any snapshot until the documented `restic unlock`
    # remediation removes the stale lock.
    locks, lock_list = storage.execute(
        "AWS_ACCESS_KEY_ID=fixture-access AWS_SECRET_ACCESS_KEY=fixture-secret-password "
        "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt "
        "RESTIC_PASSWORD_FILE=/run/backup-fixture/password "
        "restic -r s3:https://s3.test/backups/hosts/storage list locks 2>&1"
    )
    assert locks == 0 and lock_list.strip(), lock_list
    storage.fail("overalls-backup prune", timeout=60)
    status = json.loads(storage.succeed("cat /var/lib/overalls-backups/status.json"))
    assert status["state"] == "failed" and status["failure"] == "retention", status
    assert status["last_success_at"] == first_success
    assert json.loads(storage.succeed("overalls-backup list"))[0]["id"] == identity
    # Integrity checks take the same exclusive lock and refuse closed as well;
    # the published point stays intact and listable throughout.
    storage.fail("overalls-backup check", timeout=60)
    status = json.loads(storage.succeed("cat /var/lib/overalls-backups/status.json"))
    assert status["state"] == "failed" and status["failure"] == "repository", status
    assert status["last_success_at"] == first_success
    storage.succeed(
        "AWS_ACCESS_KEY_ID=fixture-access AWS_SECRET_ACCESS_KEY=fixture-secret-password "
        "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt "
        "RESTIC_PASSWORD_FILE=/run/backup-fixture/password "
        "restic -r s3:https://s3.test/backups/hosts/storage unlock"
    )
    storage.succeed("overalls-backup prune", timeout=180)
    storage.succeed("overalls-backup check", timeout=180)
    assert len(json.loads(storage.succeed("overalls-backup list"))) == 1


with subtest("database outage keeps the last complete point and cleans native snapshots"):
    database.succeed("systemctl stop postgresql.service")
    storage.fail("systemctl start overalls-backup.service", timeout=180)
    status = json.loads(storage.succeed("cat /var/lib/overalls-backups/status.json"))
    assert status["state"] == "failed" and status["failure"] == "database"
    assert status["last_success_at"] == first_success
    assert len(json.loads(storage.succeed("overalls-backup list"))) == 1
    storage.succeed('test -z "$(zfs list -H -t snapshot -o name)"')
    database.succeed("systemctl start postgresql.service")

with subtest("restore recovers deleted host bytes and a usable isolated database"):
    storage.succeed("rm /persistent/state.txt")
    storage.succeed("rm /persistent/secrets/cloak-keyring.enc")
    storage.succeed(
        "overalls-backup restore --snapshot "
        + shlex.quote(identity)
        + " --target /var/lib/recovery",
        timeout=180,
    )
    storage.succeed(
        "test \"$(find /var/lib/recovery -name state.txt -exec cat '{}' ';')\" = node-recovery"
    )
    restored_keyring = storage.succeed("find /var/lib/recovery -name cloak-keyring.enc").strip()
    restored_digest = storage.succeed("find /var/lib/recovery -name cloak-digest.json").strip()
    assert restored_keyring.startswith("/var/lib/recovery/") and "\n" not in restored_keyring
    assert restored_digest.startswith("/var/lib/recovery/") and "\n" not in restored_digest
    storage.succeed("test -s " + shlex.quote(restored_keyring))
    storage.succeed("test -s " + shlex.quote(restored_digest))
    storage.succeed('test -z "$(find /var/lib/recovery -name disposable.txt -print)"')
    storage.succeed(
        "install -d -o recovery -g recovery -m 0700 /var/lib/recovery-db /run/recovery-db"
    )
    initdb = storage.succeed("readlink -f /run/current-system/sw/bin/initdb").strip()
    pg_ctl = storage.succeed("readlink -f /run/current-system/sw/bin/pg_ctl").strip()
    storage.succeed(
        "runuser -u recovery -- " + shlex.quote(initdb) + " -D /var/lib/recovery-db --auth=trust"
    )
    storage.succeed(
        "runuser -u recovery -- "
        + shlex.quote(pg_ctl)
        + " -D /var/lib/recovery-db -l /var/lib/recovery-db/server.log -o '-h 127.0.0.1 -p 6544 -k /run/recovery-db' -w start"
    )
    storage.succeed("createdb -h 127.0.0.1 -p 6544 -U recovery isolated")
    archive = storage.succeed("find /var/lib/recovery -name database.dump").strip()
    assert archive.startswith("/var/lib/recovery/") and "\n" not in archive
    storage.succeed(
        "pg_restore --no-owner --no-acl -h 127.0.0.1 -p 6544 -U recovery -d isolated "
        + shlex.quote(archive)
    )
    assert (
        storage.succeed(
            "psql -h 127.0.0.1 -p 6544 -U recovery -d isolated -Atc 'SELECT value FROM recovery_probe'"
        ).strip()
        == "recover-me"
    )
    storage.succeed(
        "cp --preserve=mode /run/backup-fixture/marshall.env /run/backup-fixture/marshall-origin.env"
    )
    switch_database_script = (
        "import pathlib; p=pathlib.Path('/run/backup-fixture/marshall.env'); "
        "rows=[line for line in p.read_text().splitlines() "
        "if not line.startswith(('DATABASE_URL=','MARSHALL_DB_TLS='))]; "
        "rows.extend(['DATABASE_URL=ecto://recovery@127.0.0.1:6544/isolated',"
        "'MARSHALL_DB_TLS=loopback']); p.write_text('\\n'.join(rows)+'\\n'); p.chmod(0o600)"
    )
    storage.succeed("python3 -c " + shlex.quote(switch_database_script))
    wrong_keyring = "/run/backup-fixture/wrong-cloak-keyring.json"
    wrong_keyring_script = (
        "import base64,json,pathlib,secrets; "
        "p=pathlib.Path(" + repr(wrong_keyring) + "); "
        "p.write_text(json.dumps([{'id':'backup-fixture','key':base64.b64encode(secrets.token_bytes(32)).decode()}])); "
        "p.chmod(0o600)"
    )
    storage.succeed("python3 -c " + shlex.quote(wrong_keyring_script))
    write_cloak_request("verify", wrong_keyring, restored_digest)
    storage.fail("systemctl start backup-cloak-probe.service", timeout=180)
    write_cloak_request("verify", restored_keyring, restored_digest)
    storage.succeed("systemctl start backup-cloak-probe.service", timeout=180)
    probe_journal = storage.succeed("journalctl -u backup-cloak-probe.service -b --no-pager")
    assert "Marshall operator isolation verified" in probe_journal
    storage.succeed(
        "cp --preserve=mode /run/backup-fixture/marshall-origin.env /run/backup-fixture/marshall.env"
    )

with subtest("retention keeps only completed host points and their referenced components"):
    storage.succeed("printf '%s' newer > /persistent/state.txt")
    for round_index in range(3):
        outcome, _ = storage.execute("systemctl start overalls-backup.service", timeout=180)
        if outcome != 0:
            print("failed backup round:", round_index)
            print("status:", storage.succeed("cat /var/lib/overalls-backups/status.json"))
            print("journal:", storage.succeed("cat /var/lib/overalls-backups/run.json"))
        assert outcome == 0, f"backup round {round_index} failed"
    assert len(json.loads(storage.succeed("overalls-backup list"))) == 2
    storage.succeed("overalls-backup prune", "overalls-backup check", timeout=180)
    grace = json.loads(
        storage.succeed(
            "AWS_ACCESS_KEY_ID=fixture-access AWS_SECRET_ACCESS_KEY=fixture-secret-password "
            "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt "
            "RESTIC_PASSWORD_FILE=/run/backup-fixture/password "
            "restic -r s3:https://s3.test/backups/hosts/storage snapshots --json"
        )
    )
    # The interrupted run's orphaned upload ages out only after one day's grace.
    assert any(row["id"] == killed_upload for row in grace), grace

with subtest(
    "held host lock refuses operator reads and skips scheduled work without status mutation"
):
    snapshot_points = json.loads(storage.succeed("overalls-backup list"))
    assert len(snapshot_points) == 2
    before = storage.succeed("sha256sum /var/lib/overalls-backups/status.json")
    storage.succeed("rm -f /tmp/lock-held.marker")
    storage.succeed(
        "systemd-run --unit=backup-hold-lock --service-type=exec --collect "
        "/run/current-system/sw/bin/flock -x /var/lib/overalls-backups/owner.lock -c "
        "'/run/current-system/sw/bin/touch /tmp/lock-held.marker; /run/current-system/sw/bin/sleep 30'"
    )
    storage.wait_until_succeeds("test -f /tmp/lock-held.marker", timeout=30)
    # Nonzero through the packaged CLI; the refusal stderr text and exact 75
    # classification are pinned by the evaluation histories where the calling
    # process captures stderr directly.
    listed, _ = storage.execute("overalls-backup list")
    assert listed != 0, listed
    inspected, _ = storage.execute(
        "overalls-backup inspect --snapshot " + shlex.quote(snapshot_points[0]["id"])
    )
    assert inspected != 0, inspected
    restored, _ = storage.execute(
        "overalls-backup restore --snapshot "
        + shlex.quote(snapshot_points[0]["id"])
        + " --target /var/lib/locked-restore"
    )
    assert restored != 0, restored
    storage.succeed("test ! -e /var/lib/locked-restore")
    # Scheduled work (here through its real service units) skips with zero.
    for unit in [
        "overalls-backup-prune.service",
        "overalls-backup-check.service",
        "overalls-backup-read-check.service",
        "overalls-backup-cleanup.service",
    ]:
        storage.succeed("systemctl start " + unit, timeout=60)
    assert storage.succeed("sha256sum /var/lib/overalls-backups/status.json") == before
    storage.succeed("systemctl stop backup-hold-lock.service")
    storage.wait_until_succeeds("overalls-backup list >/dev/null", timeout=60)

with subtest("credential custody refusal applies through the real unit EnvironmentFile"):
    before = json.loads(storage.succeed("cat /var/lib/overalls-backups/status.json"))
    storage.succeed("chmod 0644 /run/backup-fixture/password")
    storage.fail("systemctl start overalls-backup.service", timeout=60)
    status = json.loads(storage.succeed("cat /var/lib/overalls-backups/status.json"))
    assert status["state"] == "failed" and status["failure"] == "credentials", status
    assert status["last_success_at"] == before["last_success_at"]
    listed, _ = storage.execute("overalls-backup list")
    assert listed != 0, listed
    storage.succeed("chmod 0600 /run/backup-fixture/password")
    storage.succeed("mv /run/backup-fixture/s3.env /run/backup-fixture/s3.env.held")
    storage.fail("systemctl start overalls-backup.service", timeout=60)
    status = json.loads(storage.succeed("cat /var/lib/overalls-backups/status.json"))
    assert status["state"] == "failed" and status["failure"] == "credentials", status
    storage.succeed("mv /run/backup-fixture/s3.env.held /run/backup-fixture/s3.env")
    storage.succeed("overalls-backup check", timeout=180)
    points_after = json.loads(storage.succeed("overalls-backup list"))
    assert points_after == snapshot_points

with subtest("cleanup remains usable without S3 or database credentials"):
    storage.succeed("rm /run/backup-fixture/s3.env /run/backup-fixture/marshall.env")
    storage.succeed("systemctl start overalls-backup-cleanup.service", timeout=60)
