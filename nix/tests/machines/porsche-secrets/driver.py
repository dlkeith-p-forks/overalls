start_all()
primary.wait_for_unit("multi-user.target")
primary.wait_for_unit("postgresql-setup.service")
primary.succeed("systemctl start overalls-test-migrate.service")
primary.wait_until_succeeds(
    "curl --fail --silent --cacert /run/overalls-test/ca.crt https://localhost:4443/health/ready",
    timeout=120,
)
primary.succeed("mkdir -m 0700 /run/porsche-fixture /run/porsche-sealed")
primary.succeed("gateway-operator gateway-prepare /run/porsche-fixture/first")
primary.succeed("gateway-operator gateway-configure primary /run/porsche-fixture/first")
primary.succeed("python3 /etc/porsche-secret-fixture.py seal first")
primary.succeed("systemctl start porsche.service")
primary.wait_for_open_port(22)
primary.wait_until_succeeds("python3 /etc/porsche-secret-fixture.py ready true", timeout=60)
primary.succeed("python3 /etc/porsche-secret-fixture.py custody first")
primary.fail(
    "setpriv --reuid=porsche --regid=porsche --init-groups head -c0 /etc/ssh/ssh_host_ed25519_key"
)
primary.fail(
    "setpriv --reuid=porsche --regid=porsche --init-groups head -c0 /run/overalls-secrets/porsche/token"
)
identity = primary.succeed("ssh-keygen -lf /var/lib/porsche/keys/ssh_host_ed25519_key.pub")

with subtest("another host identity cannot publish the encrypted gateway credential"):
    wrong.wait_for_unit("sshd.service")
    primary.copy_from_machine("/run/porsche-sealed/gateway.enc.json", "encrypted")
    wrong.succeed("mkdir -m 0700 /run/porsche-sealed")
    wrong.copy_from_host(
        str(primary.out_dir / "encrypted/gateway.enc.json"), "/run/porsche-sealed/gateway.enc.json"
    )
    wrong.fail("systemctl start overalls-secrets-porsche.service")
    wrong.succeed("test ! -e /run/overalls-secrets/porsche")

with subtest("authority rotation requires republishing and reloading the credential"):
    primary.succeed("gateway-operator gateway-prepare /run/porsche-fixture/next")
    primary.succeed("gateway-operator gateway-configure primary /run/porsche-fixture/next")
    primary.succeed("python3 /etc/porsche-secret-fixture.py ready false")
    primary.succeed("python3 /etc/porsche-secret-fixture.py seal next")
    primary.succeed("python3 /etc/porsche-secret-fixture.py ready false")
    primary.succeed("systemctl stop porsche.service")
    primary.succeed("systemctl restart overalls-secrets-porsche.service")
    primary.succeed("systemctl start porsche.service")
    primary.wait_until_succeeds("python3 /etc/porsche-secret-fixture.py ready true", timeout=60)
    primary.succeed("python3 /etc/porsche-secret-fixture.py custody next")
    assert (
        primary.succeed("ssh-keygen -lf /var/lib/porsche/keys/ssh_host_ed25519_key.pub") == identity
    )

with subtest("failed publication retains the previous bundle and fences startup"):
    primary.succeed("cp /run/overalls-secrets/porsche/token /run/porsche-fixture/previous")
    primary.succeed("python3 /etc/porsche-secret-fixture.py missing")
    primary.succeed("systemctl stop porsche.service")
    primary.fail("systemctl restart overalls-secrets-porsche.service")
    primary.succeed("cmp /run/porsche-fixture/previous /run/overalls-secrets/porsche/token")
    primary.fail("systemctl start porsche.service")
    primary.succeed("python3 /etc/porsche-secret-fixture.py seal next")
    primary.succeed("systemctl restart overalls-secrets-porsche.service")
    primary.succeed("systemctl start porsche.service")
    primary.wait_until_succeeds("python3 /etc/porsche-secret-fixture.py ready true", timeout=60)
    primary.succeed("python3 /etc/porsche-secret-fixture.py custody next")
