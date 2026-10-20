"""Susan fixture custody: generate, seal and scan secrets; never print them."""

import base64
import json
import os
import subprocess
import sys
from pathlib import Path

from cryptography.hazmat.primitives import serialization
from cryptography.hazmat.primitives.asymmetric import ec, rsa

root = Path("/run/susan-fixture")
sealed = Path("/run/susan-sealed/susan.enc.json")
sensitive = root / "sensitive.json"


def b64(value: bytes) -> str:
    return base64.urlsafe_b64encode(value).decode().rstrip("=")


def remember(values: list[str]) -> None:
    current: list[str] = json.loads(sensitive.read_text()) if sensitive.exists() else []
    sensitive.write_text(json.dumps(sorted(set(current + values))))
    sensitive.chmod(0o600)


def material(name: str, create: bytes) -> bytes:
    path = root / "material" / name
    if not path.exists():
        path.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
        path.write_bytes(create)
        path.chmod(0o600)
    return path.read_bytes()


def pkcs8(key: ec.EllipticCurvePrivateKey | rsa.RSAPrivateKey) -> bytes:
    return key.private_bytes(
        serialization.Encoding.PEM,
        serialization.PrivateFormat.PKCS8,
        serialization.NoEncryption(),
    )


def secrets(active: int, database_url: str) -> dict[str, str]:
    apns = material("apns.p8", pkcs8(ec.generate_private_key(ec.SECP256R1()))).decode()
    google = material(
        "google.pem", pkcs8(rsa.generate_private_key(public_exponent=65537, key_size=2048))
    ).decode()
    keys = {str(i): b64(material(f"keyring-{i}", os.urandom(32))) for i in range(1, active + 1)}
    account = {
        "type": "service_account",
        "project_id": "overalls-relay-test",
        "client_email": "relay@overalls-relay-test.iam.gserviceaccount.com",
        "private_key": google,
        "token_uri": "https://oauth2.googleapis.com/token",
    }
    values = {
        "APNS_KEY_P8": apns,
        "APNS_KEY_ID": "ABCDEFGHIJ",
        "APNS_TEAM_ID": "TEAM123456",
        "FCM_SERVICE_ACCOUNT_JSON": json.dumps(account),
        "SUSAN_PUSH_KEY_SIGNING_KEY": json.dumps({"active": active, "keys": keys}),
        "WNS_TENANT_ID": "00000000-0000-4000-8000-0000000000a1",
        "WNS_CLIENT_ID": "00000000-0000-4000-8000-0000000000a2",
        "WNS_CLIENT_SECRET": material("wns-secret", os.urandom(24)).hex(),
        "DATABASE_URL": database_url,
    }
    remember([*keys.values(), apns.splitlines()[1], google.splitlines()[1]])
    return values


def seal(active: int, omit: str | None, database_url: str, invalid: bool = False) -> None:
    root.mkdir(mode=0o700, exist_ok=True)
    sealed.parent.mkdir(mode=0o700, exist_ok=True)
    values = secrets(active, database_url)
    if omit is not None:
        values.pop(omit)
    if invalid:
        values["SUSAN_PUSH_KEY_SIGNING_KEY"] = json.dumps({"active": active + 1, "keys": {}})
    recipient = subprocess.check_output(
        ["ssh-to-age", "-i", "/etc/ssh/ssh_host_ed25519_key.pub"], text=True
    ).strip()
    payload = json.dumps({"overalls-susan": {"production": values}}).encode()
    result = subprocess.run(
        [
            "sops",
            "--encrypt",
            "--age",
            recipient,
            "--input-type",
            "json",
            "--output-type",
            "json",
            "/dev/stdin",
        ],
        input=payload,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        check=True,
    )
    temporary = sealed.with_suffix(".new")
    temporary.write_bytes(result.stdout)
    os.replace(temporary, sealed)


def files(directory: str, database_url: str, owner: int) -> None:
    """Write each secret as one credential file, as a container runtime mounts them."""
    root.mkdir(mode=0o700, exist_ok=True)
    target = Path(directory)
    target.mkdir(mode=0o700, parents=True, exist_ok=True)
    for name, value in secrets(1, database_url).items():
        path = target / name
        path.write_text(value)
        path.chmod(0o400)
        os.chown(path, owner, owner)
    os.chown(target, owner, owner)
    remember([database_url.split(":")[2].split("@")[0]])


def scan(paths: list[str]) -> None:
    """Fail if any remembered sensitive string occurs in the given files."""
    values: list[str] = json.loads(sensitive.read_text())
    assert values, "no sensitive values recorded"
    for path in paths:
        data = Path(path).read_bytes()
        for value in values:
            assert value.encode() not in data, f"sensitive fixture bytes found in {path}"


mode = sys.argv[1]
database = os.environ.get(
    "SUSAN_FIXTURE_DATABASE_URL", "ecto://susan@localhost/susan?socket_dir=/run/postgresql"
)
if mode == "seal":
    seal(int(sys.argv[2]), None, database)
elif mode == "seal-missing":
    seal(int(sys.argv[2]), sys.argv[3], database)
elif mode == "seal-invalid":
    seal(int(sys.argv[2]), None, database, invalid=True)
elif mode == "files":
    files(sys.argv[2], sys.argv[3], int(sys.argv[4]))
elif mode == "remember":
    remember(sys.argv[2:])
elif mode == "scan":
    scan(sys.argv[2:])
else:
    raise ValueError("invalid fixture mode")
