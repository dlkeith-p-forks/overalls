"""Boot the real protected operator and authenticate it over pinned SSH."""

import shlex

start_all()
control.wait_for_unit("postgresql-setup.service")
control.succeed("systemctl start overalls-test-migrate.service")
control.wait_for_unit("sshd.service")
client.wait_for_unit("multi-user.target")
client.succeed("systemctl start overalls-test-fixture.service enrollment-storage.service")
ca = control.succeed("cat /run/overalls-test/ca.crt")
client.succeed("printf '%s' " + shlex.quote(ca) + " > /run/enrollment-ca.crt")
control.wait_until_succeeds(
    "curl --fail --silent --cacert /run/overalls-test/ca.crt https://localhost:4443/health/ready",
    timeout=120,
)
client.succeed(
    "install -d -m 700 /root/enrollment; ssh-keygen -q -t ed25519 -N '' -f /root/enrollment/key"
)
public = client.succeed("cat /root/enrollment/key.pub").strip()
control.succeed(
    "install -d -m 700 -o operator -g users /home/operator/.ssh; printf '%s\\n' "
    + shlex.quote(public)
    + " > /home/operator/.ssh/authorized_keys; chown operator:users /home/operator/.ssh/authorized_keys; chmod 600 /home/operator/.ssh/authorized_keys"
)
client.succeed(
    "install -d -m 700 -o operator -g users /home/operator/.ssh; printf '%s\\n' "
    + shlex.quote(public)
    + " > /home/operator/.ssh/authorized_keys; chown operator:users /home/operator/.ssh/authorized_keys; chmod 600 /home/operator/.ssh/authorized_keys"
)
client_key = client.succeed("cat /etc/ssh/ssh_host_ed25519_key.pub").strip()
host_key = control.succeed("cat /etc/ssh/ssh_host_ed25519_key.pub").strip()
client.succeed(
    "printf '%s\\n' "
    + shlex.quote("control " + host_key + "\nclient " + client_key)
    + " > /root/enrollment/known_hosts"
)
client.succeed("python3 /etc/enrollment-fixture.py", timeout=300)
client.succeed("python3 /etc/enrollment-test.py", timeout=300)
control.succeed("test $(id -u marshall-operator) -ne 0")
# Secret diagnostics are checked on the machine without returning log content.
control.succeed(
    "journalctl --no-pager > /run/enrollment-journal; python3 -c \"import pathlib; assert b'fixture-private-marker' not in pathlib.Path('/run/enrollment-journal').read_bytes()\""
)
