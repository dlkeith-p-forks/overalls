"""Named SSH, registry permissions and activation revocation on real OpenSSH."""

import shlex

# Generate private fixtures only inside the VM. See the scoped CONTRACTS for
# the separate guarantees established by this suite and registry evaluation.
start_all()
for machine in (primary, peer):
    machine.wait_for_unit("sshd.service")
    for user in ("operator", "reader"):
        machine.wait_until_succeeds(f"test -e /var/lib/systemd/linger/{user}")
        assert machine.succeed(f"loginctl show-user {user} -p Linger --value").strip() == "yes"
        uid = machine.succeed(f"id -u {user}").strip()
        machine.wait_for_unit(f"user@{uid}.service")
    machine.fail("test -e /var/lib/systemd/linger/recovery")
    machine.succeed("install -d -m 700 /run/access-test")
    for user in ("operator", "reader", "outsider"):
        machine.succeed(f"ssh-keygen -q -t ed25519 -N '' -f /run/access-test/{user}")
    machine.succeed(
        "printf '127.0.0.1 ' >/run/access-test/known_hosts; cat /etc/ssh/ssh_host_ed25519_key.pub >>/run/access-test/known_hosts"
    )
    for user in ("operator", "reader"):
        machine.succeed(
            f"rm /etc/ssh/authorized_keys.d/{user}; install -m644 /run/access-test/{user}.pub /etc/ssh/authorized_keys.d/{user}"
        )


def ssh(user: str, key: str | None = None, command: str = "id -un") -> str:
    key = key or user
    return (
        "ssh -n -o BatchMode=yes -o IdentitiesOnly=yes -o StrictHostKeyChecking=yes "
        "-o UserKnownHostsFile=/run/access-test/known_hosts "
        f"-i /run/access-test/{key} {user}@127.0.0.1 {command}"
    )


with subtest("fleet users receive named access and explicit privileges"):
    for machine in (primary, peer):
        assert machine.succeed(ssh("reader")).strip() == "reader"
        assert machine.succeed(ssh("operator", command="sudo -n id -u")).strip() == "0"
        machine.fail(ssh("reader", command="sudo -n id -u"))
        machine.fail(ssh("root", "operator"))
        machine.fail(ssh("recovery", "operator"))
        machine.fail("id recovery")
        assert "reports" in machine.succeed(ssh("reader", command="id -Gn")).split()

with subtest("Mosh carries terminal input between hosts using administrative SSH"):
    public_key = primary.succeed("cat /run/access-test/reader.pub").strip()
    peer.succeed(f"printf '%s\\n' {shlex.quote(public_key)} >> /etc/ssh/authorized_keys.d/reader")
    host_key = peer.succeed("cat /etc/ssh/ssh_host_ed25519_key.pub").strip()
    primary.succeed(
        f"printf '%s\\n' {shlex.quote('[peer]:2222 ' + host_key)} >> /run/access-test/known_hosts"
    )
    transport = (
        "ssh -p 2222 -o BatchMode=yes -o IdentitiesOnly=yes "
        "-o StrictHostKeyChecking=yes -o UserKnownHostsFile=/run/access-test/known_hosts "
        "-i /run/access-test/reader"
    )
    # The marker requires input through the Mosh terminal, not just successful
    # SSH bootstrap or a remote command started by mosh-server.
    remote = 'read token; test "$token" = mosh-proof && id -un > /home/reader/mosh-proof'
    command = f"stty rows 24 cols 80; mosh --ssh={shlex.quote(transport)} reader@peer -- sh -c {shlex.quote(remote)}"
    primary.succeed(
        "(sleep 5; printf 'mosh-proof\\n') | TERM=xterm timeout 40 "
        f"script --quiet --return --command {shlex.quote(command)} /run/access-test/mosh.log",
        timeout=50,
    )
    assert peer.succeed("cat /home/reader/mosh-proof").strip() == "reader"
    uid = peer.succeed("id -u reader").strip()
    peer.wait_for_unit(f"user@{uid}.service")

with subtest("home-directory keys cannot bypass the registry"):
    primary.succeed("install -d -m700 -o reader -g readers /home/reader/.ssh")
    primary.succeed(
        "install -m600 -o reader -g readers /run/access-test/outsider.pub /home/reader/.ssh/authorized_keys"
    )
    primary.fail(ssh("reader", "outsider"))
    primary.fail(ssh("outsider", "reader"))

with subtest("activation replaces stale keys and group memberships"):
    fingerprint = primary.succeed("cat /etc/ssh/ssh_host_ed25519_key.pub")
    primary.succeed("touch /home/reader/retained-data")
    primary.succeed(
        "/run/current-system/specialisation/revoked/bin/switch-to-configuration test > /run/access-test/switch.log 2>&1",
        timeout=120,
    )
    primary.wait_for_unit("sshd.service")
    primary.fail(ssh("reader"))
    assert "reports" not in primary.succeed("id -Gn reader").split()
    assert primary.succeed("cat /etc/ssh/ssh_host_ed25519_key.pub") == fingerprint

with subtest("removing a user revokes the account and retains home data"):
    # Booted generation retains both independently selectable specialisations.
    primary.succeed(
        "/run/booted-system/specialisation/removed/bin/switch-to-configuration test > /run/access-test/remove.log 2>&1",
        timeout=120,
    )
    primary.fail("id reader")
    primary.succeed("test ! -e /var/lib/systemd/linger/reader")
    primary.fail(ssh("reader"))
    primary.succeed("test -f /home/reader/retained-data")
    # An untouched peer still has its original authorization.
    assert peer.succeed(ssh("reader")).strip() == "reader"
