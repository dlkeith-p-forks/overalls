import json

image = "overalls-susan"
password = "image-test-" + "7f3a9c" * 4
database = f"ecto://susan:{password}@127.0.0.1/susan"
run = (
    "podman run --rm --network host --read-only --tmpfs /tmp:rw,mode=1777 "
    "-e RELEASE_COOKIE=image-test-cookie "
    "-v /etc/susan-image-config.json:/etc/susan/config.json:ro "
    "-v /run/susan-credentials:/run/secrets/susan:ro "
)

start_all()
host.wait_for_unit("postgresql.service")
host.wait_until_succeeds("sudo -u postgres psql -c 'select 1' susan")
# The password goes through a file so sudo's command log never records it.
host.succeed(f"umask 022; echo \"alter role susan password '{password}';\" > /tmp/role.sql")
host.succeed("sudo -u postgres psql -f /tmp/role.sql && rm /tmp/role.sql")
host.succeed(f"python3 /etc/susan-fixture.py files /run/susan-credentials {database} 65532")
loaded = host.succeed("/etc/susan-image-stream | podman load")
tag = loaded.strip().split(":")[-1]
reference = f"localhost/{image}:{tag}"

with subtest("image metadata: non-root user, labels, fixed creation time"):
    inspect = json.loads(host.succeed(f"podman image inspect {reference}"))[0]
    assert inspect["Config"]["User"] == "65532:65532", inspect["Config"]
    labels = inspect["Labels"]
    assert labels["org.opencontainers.image.title"] == image, labels
    assert labels["org.opencontainers.image.created"] == "2026-10-18T00:00:00Z", labels
    assert labels["org.opencontainers.image.version"] == tag, labels
    assert "Susan.Release.migrate()" in labels["dev.overalls.migrate"], labels
    assert inspect["Created"].startswith("2026-10-18T00:00:00"), inspect["Created"]
    assert inspect["Config"]["Entrypoint"][0].endswith("/bin/susan"), inspect["Config"]
    assert inspect["Config"]["Cmd"] == ["start"], inspect["Config"]
    env = "\n".join(inspect["Config"]["Env"])
    assert password not in env and "DATABASE_URL" not in env, env

with subtest("no shell in the image root"):
    for shell in ("/bin/sh", "/bin/bash", "/usr/bin/env"):
        host.fail(f"podman run --rm --entrypoint {shell} {reference} -c true")

with subtest("migrations run as a separate release command"):
    host.succeed(f"{run} {reference} eval 'Susan.Release.migrate()'")
    tables = host.succeed(
        'sudo -u postgres psql -At susan -c "select count(*) from information_schema.tables '
        "where table_name in ('audit_entries', 'install_identities', 'oban_jobs')\""
    ).strip()
    assert tables == "3", tables

with subtest("the service starts read-only as uid 65532 and answers health"):
    host.succeed(f"{run.replace('--rm', '-d --name susan')} {reference}")
    try:
        host.wait_until_succeeds("curl -sf http://127.0.0.1:4100/healthz | grep -F ok", timeout=120)
    except Exception:
        print(host.execute("podman ps -a; podman logs susan 2>&1 | tail -60")[1])
        raise
    assert (
        host.succeed("podman inspect -f '{{.HostConfig.ReadonlyRootfs}}' susan").strip() == "true"
    )
    pid = host.succeed("podman inspect -f '{{.State.Pid}}' susan").strip()
    uid = host.succeed(f"ps -o uid= -p {pid}").strip()
    assert uid == "65532", uid
    write = host.succeed(
        "podman exec -e RELEASE_COOKIE=image-test-cookie susan "
        'bin/susan rpc \'IO.inspect(File.write("/probe", "x"))\''
    )
    assert ":erofs" in write, write
    tmp = host.succeed(
        "podman exec -e RELEASE_COOKIE=image-test-cookie susan "
        'bin/susan rpc \'IO.inspect(File.write("/tmp/probe", "x"))\''
    )
    assert ":ok" in tmp, tmp

with subtest("no secret bytes in image layers or the container filesystem"):
    host.succeed(f"podman save -o /root/image.tar {reference}")
    host.succeed("mkdir -p /root/layers && tar -xf /root/image.tar -C /root/layers")
    host.succeed(
        "for layer in $(find /root/layers -type f); do "
        "  if tar -tf $layer >/dev/null 2>&1; then mkdir -p $layer.d && tar -xf $layer -C $layer.d; fi; "
        "done"
    )
    host.succeed("podman export -o /root/container.tar susan")
    host.succeed(
        "find /root/layers /root/container.tar -type f -print0 "
        "| xargs -0 python3 /etc/susan-fixture.py scan"
    )
    host.succeed("journalctl --no-pager -o cat > /root/journal.txt")
    host.succeed("podman logs susan > /root/podman.txt 2>&1")
    host.succeed("python3 /etc/susan-fixture.py scan /root/journal.txt /root/podman.txt")
    host.succeed("podman stop susan")
