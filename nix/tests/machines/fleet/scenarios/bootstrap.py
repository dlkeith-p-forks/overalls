# @cc [owner:ghuntley,label:verification] fleet-real-independent-machines
# Each Lilly MUST use persistent overlays of actual ZFS disks and real nested
# KVM. Reports and admission MUST cross the actual authenticated control-plane
# API; fixtures MUST NOT inject capacity or substitute guest execution.
def fleet_storage_images(machine: MachineLike) -> str:
    # Replacement journeys boot the replacement provisioner from its own
    # physical storage fixture with distinct GUIDs.
    by_host = globals().get("storage_images_by_host")
    if by_host is not None:
        return by_host[machine.name]
    return storage_images


for machine in provisioners:
    for member, source in [("primary", "system0"), ("secondary", "system1")]:
        subprocess.run(
            [
                qemu_img,
                "create",
                "-f",
                "qcow2",
                "-F",
                "qcow2",
                "-b",
                str(Path(fleet_storage_images(machine)) / f"{source}.qcow2"),
                str(machine.state_dir / f"fleet-{member}.qcow2"),
            ],
            check=True,
        )

l1.start()
l1.wait_for_unit("fleet-storage.service")
host_identity(l1)
start_all()
db.wait_for_unit("postgresql-setup.service")
for machine in marshalls + provisioners + [proxy, client]:
    machine.wait_for_unit("network.target")
    machine.succeed(f"install -d -m 700 {root}")

db.wait_for_unit("chronyd.service")
for machine in marshalls + provisioners + [proxy, client, egress]:
    machine.wait_for_unit("chronyd.service")
    machine.wait_until_succeeds("chronyc waitsync 1 0.01 0 1", timeout=90)

with subtest("runtime credentials and explicit schema migration"):
    assert sql("SELECT to_regclass('public.compute_hosts') IS NULL") == "t"
    for machine in marshalls:
        transfer(db, root + "/marshall.env", machine, root + "/marshall.env")
        if agent_enabled:
            transfer(db, root + "/serper.key", machine, root + "/serper.key")
        transfer(db, root + "/ca.crt", machine, root + "/ca.crt")
        for name in ["tls.crt", "tls.key"]:
            transfer(db, f"{root}/{machine.name}/{name}", machine, f"{root}/{name}")
    m1.succeed("fleet-op migrate", timeout=180)
    for machine in marshalls:
        machine.succeed(f"touch {root}/ready")
    for machine in marshalls:
        machine.wait_for_unit(f"marshall-{machine.name}.service")
        machine.wait_until_succeeds(
            f"curl --fail --silent --cacert {root}/ca.crt https://{machine.name}:4443/health/ready",
            timeout=120,
        )
    proxy.succeed("install -d -m 750 -o root -g haproxy /var/lib/overalls-fleet-proxy")
    transfer(db, root + "/proxy/full.pem", proxy, "/var/lib/overalls-fleet-proxy/full.pem")
    transfer(db, root + "/ca.crt", proxy, "/var/lib/overalls-fleet-proxy/ca.crt")
    proxy.succeed(
        "chgrp haproxy /var/lib/overalls-fleet-proxy/* && chmod 640 /var/lib/overalls-fleet-proxy/*"
    )
    proxy.succeed(f"touch {root}/ready")
    proxy.wait_for_unit("haproxy.service")
    for machine in marshalls:
        proxy.succeed(
            f"curl -4 --fail --silent --show-error --cacert /var/lib/overalls-fleet-proxy/ca.crt "
            f"https://{machine.name}:4443/health/ready",
            timeout=15,
        )
    transfer(db, root + "/ca.crt", client, root + "/ca.crt")
    client.wait_until_succeeds(
        f"curl --fail --silent --cacert {root}/ca.crt https://control.example.test/health/ready",
        timeout=60,
    )
    assert (
        sql(
            "SELECT count(DISTINCT application_name) FROM pg_stat_activity "
            "WHERE application_name IN ('marshall:m1','marshall:m2','marshall:m3')"
        )
        == "3"
    )


# @cc [owner:ghuntley,label:verification] fleet-public-listener-separation
# Every public machine API prefix MUST return 404 even with a bearer header and
# malformed JSON. The independently reachable fleet listener MUST remain healthy
# and MUST NOT serve browser routes. Subsequent enrollment must use that listener.
with subtest("public browser and private fleet listeners remain separate"):
    client.wait_until_succeeds(
        f"curl -4 --fail --silent --cacert {root}/ca.crt "
        "https://control.example.test:5443/health/ready",
        timeout=60,
    )
    for service in ["provisioners", "ssh", "ziggy", "audi", "fleet"]:
        status = client.succeed(
            f"curl -4 --silent --show-error --cacert {root}/ca.crt "
            "-o /dev/null -w '%{http_code}' -H 'Content-Type: application/json' "
            "-H 'Authorization: Bearer isolated-test' --data 'invalid-json' "
            f"https://control.example.test/api/{service}/v1/identity"
        ).strip()
        assert status == "404", (service, status)
    status = client.succeed(
        f"curl -4 --silent --show-error --cacert {root}/ca.crt "
        "-o /dev/null -w '%{http_code}' https://control.example.test:5443/sign-in"
    ).strip()
    assert status == "404", status
