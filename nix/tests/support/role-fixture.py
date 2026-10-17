"""Generate ephemeral credentials inside an isolated NixOS test machine."""

import base64
import json
import os
import secrets
import subprocess
from pathlib import Path


# @cc [owner:ghuntley,label:verification] role-fixture-runtime-secrets
# Fixture keys and passwords MUST be generated at runtime, written privately,
# and never printed or passed in subprocess arguments. No cloud is contacted.
def main() -> None:
    os.umask(0o077)
    root = Path("/run/overalls-test")
    root.mkdir(mode=0o700, exist_ok=True)
    subprocess.run(
        [
            "openssl",
            "req",
            "-x509",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-days",
            "2",
            "-subj",
            "/CN=Overalls test CA",
            "-addext",
            "basicConstraints=critical,CA:TRUE",
            "-addext",
            "keyUsage=critical,keyCertSign,cRLSign",
            "-addext",
            "subjectKeyIdentifier=hash",
            "-addext",
            "authorityKeyIdentifier=keyid:always",
            "-keyout",
            str(root / "ca.key"),
            "-out",
            str(root / "ca.crt"),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    subprocess.run(
        [
            "openssl",
            "req",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-subj",
            "/CN=localhost",
            "-keyout",
            str(root / "tls.key"),
            "-out",
            str(root / "tls.csr"),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    (root / "extensions").write_text(
        "basicConstraints=critical,CA:FALSE\n"
        "keyUsage=critical,digitalSignature,keyEncipherment\n"
        "extendedKeyUsage=serverAuth\n"
        "subjectKeyIdentifier=hash\n"
        "authorityKeyIdentifier=keyid:always\n"
        "subjectAltName=DNS:localhost,DNS:control.example.test,IP:127.0.0.1\n"
    )
    subprocess.run(
        [
            "openssl",
            "x509",
            "-req",
            "-in",
            str(root / "tls.csr"),
            "-CA",
            str(root / "ca.crt"),
            "-CAkey",
            str(root / "ca.key"),
            "-CAcreateserial",
            "-days",
            "2",
            "-extfile",
            str(root / "extensions"),
            "-out",
            str(root / "tls.crt"),
        ],
        check=True,
        stdout=subprocess.DEVNULL,
        stderr=subprocess.DEVNULL,
    )
    password = secrets.token_hex(32)
    values = {
        "DATABASE_URL": f"postgresql://marshall:{password}@localhost/marshall",
        "MARSHALL_CLOAK_KEYS": json.dumps(
            [{"id": "fixture", "key": base64.b64encode(os.urandom(32)).decode()}]
        ),
        "SECRET_KEY_BASE": secrets.token_hex(64),
        "TOKEN_SIGNING_SECRET": secrets.token_hex(64),
        "MARSHALL_SMTP_HOST": "smtp.example.test",
        "MARSHALL_SMTP_USERNAME": "fixture",
        "MARSHALL_SMTP_PASSWORD": secrets.token_hex(32),
        "MARSHALL_SMTP_CA_CERTFILE": "/etc/ssl/certs/ca-certificates.crt",
        "MARSHALL_MAIL_FROM": "fixture@example.test",
        # Deliberately conflicting public settings test the module's authority.
        "MARSHALL_INSTANCE_ID": "incorrect-shared-identity",
        "MARSHALL_DB_TLS": "loopback",
        "MARSHALL_BIND_IP": "0.0.0.0",
        "PORT": "4999",
    }
    (root / "marshall.env").write_text(
        "".join(f"{key}='{value}'\n" for key, value in values.items())
    )
    (root / "database.sql").write_text(f"ALTER ROLE marshall WITH LOGIN PASSWORD '{password}';\n")
    host = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    credential_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    (root / "lilly.json").write_text(
        json.dumps(
            {
                "version": 1,
                "host_id": host,
                "credential_id": credential_id,
                "credential": credential_id + ":" + secrets.token_urlsafe(32),
                "expires_at": "9999-01-01T00:00:00Z",
            }
        )
    )


if __name__ == "__main__":
    main()
