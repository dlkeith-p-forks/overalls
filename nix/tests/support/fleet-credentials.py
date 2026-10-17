"""Runtime-only credentials for the isolated multi-machine fixture."""

import base64
import json
import os
import secrets
import subprocess
import uuid
from pathlib import Path


# @cc [owner:ghuntley,label:security] fleet-runtime-credential-custody
# Private keys, application secrets and database passwords MUST be generated
# inside the disposable fixture, never embedded in images or printed. Each TLS
# endpoint MUST have its own leaf key under the shared test CA.
def main() -> None:
    os.umask(0o077)
    root = Path("/var/lib/overalls-fleet")
    root.mkdir(mode=0o700, exist_ok=True)
    if (root / "initialized").exists():
        return

    def openssl(*args: str) -> None:
        subprocess.run(
            ["openssl", *args], check=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL
        )

    openssl(
        "req",
        "-x509",
        "-newkey",
        "rsa:2048",
        "-nodes",
        "-days",
        "2",
        "-subj",
        "/CN=Overalls fleet fixture CA",
        "-addext",
        "basicConstraints=critical,CA:TRUE",
        "-addext",
        "keyUsage=critical,keyCertSign,cRLSign",
        "-keyout",
        str(root / "ca.key"),
        "-out",
        str(root / "ca.crt"),
    )
    for node in ["db", "m1", "m2", "m3", "proxy"]:
        leaf = root / node
        leaf.mkdir(mode=0o700)
        openssl(
            "req",
            "-newkey",
            "rsa:2048",
            "-nodes",
            "-subj",
            f"/CN={node}",
            "-keyout",
            str(leaf / "tls.key"),
            "-out",
            str(leaf / "tls.csr"),
        )
        names = [f"DNS:{node}"] + (["DNS:control.example.test"] if node == "proxy" else [])
        (leaf / "extensions").write_text(
            "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature,keyEncipherment\n"
            "extendedKeyUsage=serverAuth\nsubjectKeyIdentifier=hash\nauthorityKeyIdentifier=keyid:always\n"
            + "subjectAltName="
            + ",".join(names)
            + "\n"
        )
        openssl(
            "x509",
            "-req",
            "-in",
            str(leaf / "tls.csr"),
            "-CA",
            str(root / "ca.crt"),
            "-CAkey",
            str(root / "ca.key"),
            "-CAcreateserial",
            "-days",
            "2",
            "-extfile",
            str(leaf / "extensions"),
            "-out",
            str(leaf / "tls.crt"),
        )
    proxy = root / "proxy"
    (proxy / "full.pem").write_bytes(
        (proxy / "tls.key").read_bytes() + (proxy / "tls.crt").read_bytes()
    )
    password = secrets.token_hex(32)
    fixture = str(uuid.uuid4())
    env = {
        "DATABASE_URL": f"postgresql://marshall:{password}@db/marshall",
        "MARSHALL_CLOAK_KEYS": json.dumps(
            [{"id": "fleet", "key": base64.b64encode(os.urandom(32)).decode()}]
        ),
        "SECRET_KEY_BASE": secrets.token_hex(64),
        "TOKEN_SIGNING_SECRET": secrets.token_hex(64),
        "MARSHALL_SMTP_HOST": "smtp.example.test",
        "MARSHALL_SMTP_USERNAME": "fixture",
        "MARSHALL_SMTP_PASSWORD": secrets.token_hex(32),
        "MARSHALL_SMTP_CA_CERTFILE": "/etc/ssl/certs/ca-certificates.crt",
        "MARSHALL_MAIL_FROM": "fixture@example.test",
        "FLEET_FIXTURE_ID": fixture,
    }
    (root / "marshall.env").write_text("".join(f"{key}='{value}'\n" for key, value in env.items()))
    (root / "serper.key").write_text("synthetic-serper-private\n")
    (root / "database.sql").write_text(
        f"ALTER ROLE marshall WITH LOGIN PASSWORD '{password}';\n"
        "CREATE TABLE IF NOT EXISTS overalls_fleet_fixture (id uuid PRIMARY KEY);\n"
        f"INSERT INTO overalls_fleet_fixture VALUES ('{fixture}') ON CONFLICT DO NOTHING;\n"
        "ALTER TABLE overalls_fleet_fixture OWNER TO marshall;\n"
    )
    (root / "initialized").touch(mode=0o600)


if __name__ == "__main__":
    main()
