"""Real OpenSSH exercises the patched OTP certificate transport and user proof."""

import shlex

start_all()
server.wait_for_unit("certificate-server.service")
server.wait_for_open_port(2222, timeout=60)
client.succeed("install -m 600 /etc/ssh-test-key /root/identity")
client.succeed(
    "printf '@cert-authority server ' >/root/known_hosts; cat /etc/ssh-ca.pub >>/root/known_hosts"
)
command = (
    "ssh -F /dev/null -p 2222 -i /root/identity -o BatchMode=yes "
    "-o StrictHostKeyChecking=yes -o HostKeyAlgorithms=ssh-ed25519-cert-v01@openssh.com "
    "-o UserKnownHostsFile=/root/known_hosts -o GlobalKnownHostsFile=/dev/null "
    "-o HostKeyAlias=server -o RekeyLimit=16K "
)
for exchange in [
    "curve25519-sha256",
    "diffie-hellman-group14-sha256",
    "diffie-hellman-group-exchange-sha256",
    "ecdh-sha2-nistp256",
    "mlkem768x25519-sha256",
]:
    with subtest("certificate handshake and rekey: " + exchange):
        output = client.succeed(command + "-o KexAlgorithms=" + exchange + " server test")
        assert output == "certified\n" * 8192
with subtest("RSA user proof remains independent of the Ed25519 host certificate"):
    client.succeed("ssh-keygen -q -t rsa -b 3072 -N '' -f /root/rsa-identity")
    rsa_public: str = client.succeed("cat /root/rsa-identity.pub")
    server.succeed(
        "printf %s " + shlex.quote(rsa_public) + " >>/run/certificate-server/authorized_keys"
    )
    output = client.succeed(
        command.replace("/root/identity", "/root/rsa-identity") + " server test"
    )
    assert output == "certified\n" * 8192
with subtest("wrong principal and unsigned fallback are rejected"):
    client.fail(command.replace("HostKeyAlias=server", "HostKeyAlias=other") + " server test")
    client.fail(command.replace("ssh-ed25519-cert-v01@openssh.com", "ssh-ed25519") + " server test")
with subtest("unknown CA and explicit revocation are rejected"):
    client.succeed("cp /root/known_hosts /root/retained-trust; : >/root/known_hosts")
    client.fail(command + " server test")
    client.succeed(
        "cp /root/retained-trust /root/known_hosts; printf '@revoked server ' >>/root/known_hosts; cat /etc/ssh-ca.pub >>/root/known_hosts"
    )
    client.fail(command + " server test")
with subtest("valid host trust does not authenticate an unrelated user key"):
    client.succeed(
        "cp /root/retained-trust /root/known_hosts; ssh-keygen -q -t ed25519 -N '' -f /root/other"
    )
    client.fail(command.replace("/root/identity", "/root/other") + " server test")
with subtest("expired and future host certificates are rejected by OpenSSH"):
    for validity in ["-2d:-1d", "+1d:+2d"]:
        server.succeed(
            "cd /run/certificate-server; ssh-keygen -q -s ca -I invalid-time -h -n server -V "
            + validity
            + " ssh_host_ed25519_key.pub"
        )
        client.fail(command + " server test")
