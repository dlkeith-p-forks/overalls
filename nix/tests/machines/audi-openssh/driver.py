import shlex


def succeed_ssh(command: str) -> str:
    return client.succeed("python3 /etc/bounded-ssh.py " + shlex.quote(command), timeout=75)


def fail_ssh(command: str) -> str:
    status, output = client.execute(
        "python3 /etc/bounded-ssh.py " + shlex.quote(command), timeout=75
    )
    assert status == 255, "Expected an SSH refusal, not a timeout or fixture failure"
    return output


start_all()
for unit in [
    "fixture.service",
    "outer.service",
    "inner.service",
    "middle.service",
    "lookup.service",
]:
    client.wait_for_unit(unit)
for port in [2222, 2223, 2224, 4443]:
    client.wait_for_open_port(port)

host = "vm-11111111111141118111111111111111.vm.example.test"
client.succeed("ssh-agent -a /run/audi-openssh/agent >/run/audi-openssh/agent.env")
client.succeed("SSH_AUTH_SOCK=/run/audi-openssh/agent ssh-add /run/audi-openssh/client")
command = (
    "SSL_CERT_FILE=/run/audi-openssh/ca.crt SSH_AUTH_SOCK=/run/audi-openssh/agent "
    "ssh -F /run/audi-openssh/config -o BatchMode=yes -o StrictHostKeyChecking=yes "
    "guest@" + host + " 'printf guest-ok'"
)
assert succeed_ssh(command).strip() == "guest-ok"

# A cached outer key cannot override a fresh lookup pointing at another key.
client.succeed(
    "printf '%s ' '"
    + host
    + "' >>/root/.ssh/known_hosts; cat /run/audi-openssh/gateway_a.pub >>/root/.ssh/known_hosts"
)
client.succeed(
    "printf '%s ' '"
    + host
    + "' >/run/audi-openssh/published_key; cat /run/audi-openssh/gateway_b.pub >>/run/audi-openssh/published_key"
)
fail_ssh(command)
client.succeed(
    "cp /run/audi-openssh/gateway_b /run/audi-openssh/gateway_active; systemctl restart outer.service"
)
client.wait_for_open_port(2222)
assert succeed_ssh(command).strip() == "guest-ok"

# Valid key bodies on error/redirect responses must still fail closed.
for status in [503, 302, 300]:
    client.succeed("printf " + str(status) + " >/run/audi-openssh/status")
    fail_ssh(command)
client.succeed("printf 200 >/run/audi-openssh/status")
client.succeed("touch /run/audi-openssh/oversized")
fail_ssh(command)
client.succeed("rm /run/audi-openssh/oversized")
fail_ssh(
    command.replace(
        "SSL_CERT_FILE=/run/audi-openssh/ca.crt",
        "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt",
    )
)
assert succeed_ssh(command).strip() == "guest-ok"

# The inner guest's key has its own ordinary known-hosts trust boundary.
client.succeed("cp /root/.ssh/known_hosts /run/audi-openssh/known_hosts; : >/root/.ssh/known_hosts")
fail_ssh(command)
client.succeed(
    "cp /run/audi-openssh/known_hosts /root/.ssh/known_hosts; systemctl stop lookup.service"
)
fail_ssh(command)

# Execute both fixture Inception profiles, including both independently
# expanded KnownHostsCommands. This remains an sshd/HTTPS fixture, not a VM.
client.succeed(
    "systemctl start lookup.service; cp /run/audi-openssh/gateway_b.pub /run/audi-openssh/published_gateway"
)
client.wait_for_open_port(4443)
for service in ["porsche", "audi"]:
    nested = (
        "SSL_CERT_FILE=/run/audi-openssh/ca.crt SSH_AUTH_SOCK=/run/audi-openssh/agent "
        "ssh -F /run/audi-openssh/inception-config -o BatchMode=yes guest@"
        + service
        + ".vm-11111111111141118111111111111111.inception.vm.example.test 'printf nested-ok'"
    )
    assert succeed_ssh(nested).strip() == "nested-ok"
    client.succeed("cp /run/audi-openssh/gateway_a.pub /run/audi-openssh/published_gateway")
    fail_ssh(nested)
    client.succeed("cp /run/audi-openssh/gateway_b.pub /run/audi-openssh/published_gateway")
    client.succeed("cp /run/audi-openssh/gateway_a.pub /run/audi-openssh/published_inner")
    fail_ssh(nested)
    client.succeed("cp /run/audi-openssh/guest_key.pub /run/audi-openssh/published_inner")
    for status in [503, 302, 300]:
        client.succeed("printf " + str(status) + " >/run/audi-openssh/status")
        fail_ssh(nested)
    client.succeed("printf 200 >/run/audi-openssh/status; touch /run/audi-openssh/oversized")
    fail_ssh(nested)
    client.succeed("rm /run/audi-openssh/oversized")
    fail_ssh(
        nested.replace(
            "SSL_CERT_FILE=/run/audi-openssh/ca.crt",
            "SSL_CERT_FILE=/etc/ssl/certs/ca-certificates.crt",
        )
    )
    assert succeed_ssh(nested).strip() == "nested-ok"

# The workload profile adds an independently verified middle Audi connection.
# Only the fixture relay's destination changes; the fixture config stays unchanged.
client.succeed(
    "touch /run/audi-openssh/nested-workload; cp /run/audi-openssh/inner_gateway.pub /run/audi-openssh/published_inner"
)
workload = (
    "SSL_CERT_FILE=/run/audi-openssh/ca.crt SSH_AUTH_SOCK=/run/audi-openssh/agent "
    "ssh -F /run/audi-openssh/workload-config -o BatchMode=yes -o StrictHostKeyChecking=yes guest@"
    "vm-11111111111141118111111111111111.apps.vm-11111111111141118111111111111111.inception.vm.example.test "
    "'test -z \"$SSH_AUTH_SOCK\" && printf workload-ok'"
)
assert succeed_ssh(workload).strip() == "workload-ok"
for layer, correct in [("gateway", "gateway_b"), ("inner", "inner_gateway")]:
    client.succeed("cp /run/audi-openssh/gateway_a.pub /run/audi-openssh/published_" + layer)
    fail_ssh(workload)
    client.succeed("cp /run/audi-openssh/" + correct + ".pub /run/audi-openssh/published_" + layer)
    assert succeed_ssh(workload).strip() == "workload-ok"
client.succeed(
    "cp /root/.ssh/known_hosts /run/audi-openssh/workload-known-hosts; : >/root/.ssh/known_hosts"
)
fail_ssh(workload)
client.succeed(
    "cp /run/audi-openssh/workload-known-hosts /root/.ssh/known_hosts; printf 503 >/run/audi-openssh/status"
)
fail_ssh(workload)
client.succeed("printf 200 >/run/audi-openssh/status; systemctl stop lookup.service")
fail_ssh(workload)
