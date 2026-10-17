"""Privileged, retryable Inception preparation; serving units never migrate."""

import fcntl
import hashlib
import json
import os
import secrets
import shutil
import stat
import subprocess
import sys
import tempfile
from pathlib import Path
from typing import TypedDict

from runtime import (
    Identity,
    SetupError,
    application_environment,
    encode,
    environment_file,
    identities,
    private_directory,
    publish,
    read_private,
    smtp_environment,
)

STATE = Path("/var/lib/inception")
RUNTIME = Path("/run/inception")
PUBLIC = Path("/run/inception-public")
WORKSPACE = Path("/workspace")


class Config(TypedDict):
    openssl: str
    source: str
    git: str
    runuser: str
    psql: str
    system_ca: str


def command(
    arguments: list[str], data: bytes | None = None, env: dict[str, str] | None = None
) -> bytes:
    result = subprocess.run(
        arguments,
        input=data,
        stdout=subprocess.PIPE,
        stderr=subprocess.DEVNULL,
        env=env,
        timeout=180,
    )
    if result.returncode != 0:
        raise SetupError("preparation command failed")
    return result.stdout


def public_directory() -> None:
    PUBLIC.mkdir(mode=0o755, exist_ok=True)
    info = PUBLIC.lstat()
    if not stat.S_ISDIR(info.st_mode) or info.st_uid != os.getuid() or info.st_mode & 0o022:
        raise SetupError("public certificate directory invalid")
    # Bootstrap deliberately runs under umask 0077. mkdir's requested mode is
    # masked, so explicitly make this certificates-only directory traversable
    # by the unprivileged Marshall service after validating its owner and type.
    PUBLIC.chmod(0o755)


def public_certificate(name: str, data: bytes) -> None:
    public_directory()
    publish(PUBLIC / name, data)
    (PUBLIC / name).chmod(0o644)


def certificates(openssl: str) -> None:
    """@cc [owner:ghuntley,label:security;recovery] inception-private-tls-identities
    TLS private keys MUST be generated per instance outside the image and reused
    on restart. Only certificates may enter the public runtime directory. Partial
    unpublished generation MUST NOT replace a published certificate directory.
    """
    target = STATE / "tls"
    if not os.path.lexists(target):
        with tempfile.TemporaryDirectory(prefix=".tls-", dir=STATE) as temporary:
            temporary = Path(temporary)
            command(
                [
                    openssl,
                    "req",
                    "-x509",
                    "-newkey",
                    "rsa:2048",
                    "-nodes",
                    "-sha256",
                    "-days",
                    "3650",
                    "-subj",
                    "/CN=Inception instance CA",
                    "-addext",
                    "basicConstraints=critical,CA:TRUE",
                    "-addext",
                    "keyUsage=critical,keyCertSign,cRLSign",
                    "-keyout",
                    str(temporary / "ca.key"),
                    "-out",
                    str(temporary / "ca.crt"),
                ]
            )
            for name in ["database", "marshall"]:
                command(
                    [
                        openssl,
                        "req",
                        "-new",
                        "-newkey",
                        "rsa:2048",
                        "-nodes",
                        "-subj",
                        "/CN=localhost",
                        "-keyout",
                        str(temporary / (name + ".key")),
                        "-out",
                        str(temporary / (name + ".csr")),
                    ]
                )
                extensions = temporary / "extensions"
                extensions.write_text(
                    "subjectAltName=DNS:localhost,IP:127.0.0.1\n"
                    "extendedKeyUsage=serverAuth\n"
                    "basicConstraints=critical,CA:FALSE\n"
                    "keyUsage=critical,digitalSignature,keyEncipherment\n"
                )
                command(
                    [
                        openssl,
                        "x509",
                        "-req",
                        "-in",
                        str(temporary / (name + ".csr")),
                        "-CA",
                        str(temporary / "ca.crt"),
                        "-CAkey",
                        str(temporary / "ca.key"),
                        "-set_serial",
                        "0x" + secrets.token_hex(16),
                        "-days",
                        "1825",
                        "-sha256",
                        "-extfile",
                        str(extensions),
                        "-out",
                        str(temporary / (name + ".crt")),
                    ]
                )
                (temporary / (name + ".csr")).unlink()
            (temporary / "extensions").unlink()
            for path in temporary.iterdir():
                path.chmod(0o600)
                with path.open("rb") as stream:
                    os.fsync(stream.fileno())
            # TemporaryDirectory cleans the old name after the atomic publication.
            os.rename(temporary, target)
            fd = os.open(STATE, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
    private_directory(target)
    for name in ["ca", "database", "marshall"]:
        read_private(target / (name + ".key"))
        read_private(target / (name + ".crt"))
        key = command([openssl, "pkey", "-in", str(target / (name + ".key")), "-pubout"])
        certificate = command(
            [openssl, "x509", "-in", str(target / (name + ".crt")), "-pubkey", "-noout"]
        )
        if key != certificate:
            raise SetupError("TLS identity mismatch")
    for name in ["database", "marshall"]:
        command(
            [
                openssl,
                "verify",
                "-CAfile",
                str(target / "ca.crt"),
                "-verify_hostname",
                "localhost",
                str(target / (name + ".crt")),
            ]
        )
    public_certificate("ca.crt", read_private(target / "ca.crt"))


def prepare_environment(identity: Identity, system_ca: str) -> None:
    bundle: object = json.loads(read_private(RUNTIME / "smtp.json"))
    smtp = smtp_environment(bundle, RUNTIME)
    if isinstance(bundle, dict) and "ca_pem" in bundle:
        public_certificate("smtp-ca.crt", read_private(RUNTIME / "smtp-ca.crt"))
    else:
        public_certificate("smtp-ca.crt", Path(system_ca).read_bytes())
    smtp["MARSHALL_SMTP_CA_CERTFILE"] = str(PUBLIC / "smtp-ca.crt")
    env = application_environment(identity, smtp, PUBLIC / "ca.crt")
    publish(RUNTIME / "marshall.env", environment_file(env))
    publish(RUNTIME / "environment.json", encode(env))


def prepare_database(identity: Identity, config: Config) -> None:
    """@cc [owner:ghuntley,label:recovery] inception-database-password-stability
    Database preparation MUST use the persisted per-instance password and send it
    to local PostgreSQL on stdin, never in argv or diagnostics. Retry MUST NOT
    generate or rotate a password. The Nix PostgreSQL module owns role/database creation.
    """
    password = identity["database_password"]  # validated hexadecimal, not external SMTP input
    sql = (
        "SET log_statement = 'none'; SET log_min_error_statement = 'panic';\n"
        "ALTER ROLE marshall WITH LOGIN PASSWORD '" + password + "';\n"
    )
    command(
        [
            config["runuser"],
            "-u",
            "postgres",
            "--",
            config["psql"],
            "--no-psqlrc",
            "--set",
            "ON_ERROR_STOP=1",
            "--dbname",
            "postgres",
        ],
        sql.encode(),
    )


def prepare_source(source: str, git: str) -> None:
    """@cc [owner:ghuntley,label:recovery] inception-source-edits-survive
    Source preparation MUST populate a new workspace atomically and MUST NOT copy
    over an existing developer workspace on restart or image update.
    """
    workspace = WORKSPACE
    workspace.mkdir(mode=0o755, exist_ok=True)
    target = workspace / "overalls"
    if os.path.lexists(target):
        if target.is_symlink() or not target.is_dir():
            raise SetupError("development workspace invalid")
        return
    with tempfile.TemporaryDirectory(prefix=".overalls-", dir=workspace) as temporary:
        tree = Path(temporary) / "source"
        shutil.copytree(source, tree, symlinks=True)
        for path in [tree, *tree.rglob("*")]:
            if not path.is_symlink():
                path.chmod(path.stat().st_mode | stat.S_IWUSR)
        command([git, "-C", str(tree), "init", "--initial-branch=inception"])
        command([git, "-C", str(tree), "add", "."])
        command(
            [
                git,
                "-C",
                str(tree),
                "-c",
                "user.name=Overalls source image",
                "-c",
                "user.email=source-image@localhost",
                "commit",
                "-m",
                "Bundled development source",
            ]
        )
        os.rename(tree, target)


def main() -> None:
    if os.getuid() != 0:
        raise SetupError("root preparation required")
    action, config_path, *arguments = sys.argv[1:]
    config = json.loads(Path(config_path).read_bytes())
    private_directory(STATE)
    private_directory(RUNTIME)
    fd = os.open(STATE / "bootstrap.lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    with os.fdopen(fd, "rb") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        identity = identities(STATE)
        if action == "identity":
            certificates(config["openssl"])
            hostid = hashlib.sha256(identity["instance_id"].encode()).digest()[:4]
            if hostid == bytes(4):
                hostid = b"\x01\x00\x00\x00"
            hostid_path = Path("/etc/hostid")
            if os.path.lexists(hostid_path):
                if hostid_path.is_symlink() or hostid_path.read_bytes() != hostid:
                    raise SetupError("host identity changed")
            else:
                publish(hostid_path, hostid, replace=False)
                hostid_path.chmod(0o644)
            prepare_source(config["source"], config["git"])
        elif action == "environment":
            prepare_environment(identity, config["system_ca"])
        elif action == "database":
            prepare_database(identity, config)
        elif action == "exec":
            env = {
                **os.environ,
                **json.loads(read_private(RUNTIME / "environment.json")),
                "RELEASE_COOKIE": secrets.token_hex(32),
                "PHX_SERVER": "false",
            }
            # The child may perform long-running application work; it does not own
            # the bootstrap lock. Unit dependencies serialize bootstrap actions.
            fcntl.flock(lock, fcntl.LOCK_UN)
            os.execve(arguments[0], arguments, env)
        else:
            raise SetupError("unknown preparation action")


if __name__ == "__main__":
    try:
        main()
    except SetupError as error:
        # SetupError messages are fixed local reason strings, never subprocess
        # output, argv, JSON values or database errors.
        print("Inception preparation failed: " + str(error), file=sys.stderr)
        sys.exit(1)
    except Exception:
        # Underlying exceptions can contain credentials, SQL or environment values.
        print(
            "Inception preparation failed; check private inputs and service prerequisites",
            file=sys.stderr,
        )
        sys.exit(1)
