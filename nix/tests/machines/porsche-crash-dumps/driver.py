"""Actual service captures; only public keys and encrypted bytes cross machines."""

import shlex

start_all()
analyst.succeed(
    "umask 077; mkdir -p /root/diagnostics; openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:3072 -out /root/diagnostics/private.pem 2>/dev/null"
)
analyst.succeed(
    "openssl pkey -in /root/diagnostics/private.pem -pubout -out /tmp/shared/porsche-public.pem"
)
gateway.succeed(
    "mkdir -m 0755 /run/porsche-fixture; cp /tmp/shared/porsche-public.pem /run/porsche-fixture/public.pem; chmod 0644 /run/porsche-fixture/public.pem"
)
gateway.succeed(
    "printf '%s' porsche_gateway_AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA > /run/porsche-fixture/gateway.token; chmod 0600 /run/porsche-fixture/gateway.token"
)

for index in range(4):
    gateway.succeed("systemctl start porsche.service")
    gateway.wait_for_open_port(22, timeout=60)
    gateway.succeed("python3 /etc/check-dumps.py running")
    invocation = gateway.succeed("systemctl show porsche.service -p InvocationID --value").strip()
    assert len(invocation) == 32 and all(c in "0123456789abcdef" for c in invocation)
    gateway.succeed("systemctl kill --kill-whom=main --signal=SIGUSR1 porsche.service")
    gateway.wait_until_succeeds("! systemctl is-active --quiet porsche.service", timeout=25)
    gateway.wait_until_succeeds(
        "test -f /var/lib/porsche-crash-dumps/" + invocation + ".reported", timeout=25
    )
    gateway.succeed("python3 /etc/check-dumps.py")
    if index == 0:
        gateway.succeed(
            "cp /var/lib/porsche-crash-dumps/"
            + invocation
            + ".dump /tmp/shared/porsche-encrypted.dump"
        )
        analyst.succeed("cp /tmp/shared/porsche-encrypted.dump /root/diagnostics/encrypted.dump")
        expression = 'ok = crashdump:pem_decrypt("/root/diagnostics/encrypted.dump", "/root/diagnostics/private.pem", "/root/diagnostics/plain.dump"), halt().'
        analyst.succeed("erl +S 2:2 -noshell -eval " + shlex.quote(expression))
        analyst.succeed(
            'python3 -c \'from pathlib import Path; data=Path("/root/diagnostics/plain.dump").read_bytes(); assert b"=erl_crash_dump" in data; assert b"Elixir.Porsche.Listener" in data\''
        )
        analyst.succeed("rm /root/diagnostics/plain.dump /tmp/shared/porsche-encrypted.dump")

gateway.succeed("test $(find /var/lib/porsche-crash-dumps -name '*.dump' | wc -l) -eq 3")
gateway.succeed(
    'python3 -c \'from pathlib import Path; import os,time; path=min(Path("/var/lib/porsche-crash-dumps").glob("*.dump"),key=lambda p:p.stat().st_mtime); os.utime(path,(time.time()-8*86400,)*2)\''
)
gateway.succeed("systemctl start overalls-crash-dump-retention.service")
gateway.succeed("test $(find /var/lib/porsche-crash-dumps -name '*.dump' | wc -l) -eq 2")

analyst.succeed(
    "openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:2048 -out /root/diagnostics/weak.pem 2>/dev/null; openssl pkey -in /root/diagnostics/weak.pem -pubout -out /tmp/shared/porsche-weak.pem"
)
gateway.succeed(
    "cp /tmp/shared/porsche-weak.pem /run/porsche-fixture/public.pem; systemctl reset-failed porsche.service"
)
gateway.execute("systemctl start porsche.service")
gateway.wait_until_succeeds("systemctl is-failed --quiet porsche.service", timeout=30)
gateway.succeed("test $(find /var/lib/porsche-crash-dumps -name '*.dump' | wc -l) -eq 2")
gateway.succeed("rm /run/porsche-fixture/public.pem; systemctl reset-failed porsche.service")
gateway.execute("systemctl start porsche.service")
gateway.wait_until_succeeds("systemctl is-failed --quiet porsche.service", timeout=30)
gateway.succeed("python3 /etc/check-dumps.py")
gateway.wait_for_open_port(2222)
