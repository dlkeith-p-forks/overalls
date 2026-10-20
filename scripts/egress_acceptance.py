#!/usr/bin/env python3
"""Opt-in, resumable production guest egress checks. See docs/acceptance/egress-acceptance.md."""

import argparse
import base64
import contextlib
import datetime
import hashlib
import ipaddress
import json
import os
import re
import shlex
import signal
import socket
import subprocess
import time
import urllib.request
import uuid
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Literal

Kind = Literal["nixos", "ubuntu", "customer"]
KINDS: tuple[Kind, ...] = ("nixos", "ubuntu", "customer")
ARTIFACT = "https://cdn.jsdelivr.net/npm/is-number@7.0.0/index.js"


class PublicReferenceUnavailable(RuntimeError):
    """A bounded public GET exhausted transient failures; trust was not granted."""


def mapping(value: object) -> dict[str, object]:
    if not isinstance(value, dict) or not all(isinstance(key, str) for key in value):
        raise ValueError("Expected a JSON object")
    return {key: item for key, item in value.items()}


def text(value: object) -> str:
    if not isinstance(value, str) or not value or any(ord(c) < 32 for c in value):
        raise ValueError("Expected nonempty text without control characters")
    return value


def decode(raw: str) -> dict[str, object]:
    value: object = json.loads(raw)
    return mapping(value)


@dataclass(frozen=True)
class Fixture:
    kind: Kind
    id: str
    name: str
    image_id: str
    profile: str
    ssh_host: str
    request_id: str

    @classmethod
    def parse(cls, kind: Kind, value: object, prefix: str, host: str) -> "Fixture":
        row = mapping(value)
        identifier = text(row["id"])
        if str(uuid.UUID(identifier)) != identifier:
            raise ValueError("Noncanonical VM UUID")
        name = text(row["name"])
        profile = text(row["profile"])
        image = text(row["image_id"])
        ssh_host = text(row["ssh_host"])
        request = text(row["request_id"])
        label = ssh_host.removesuffix(".apps." + host)
        if (
            name != prefix + "-" + kind
            or request != name + "-create"
            or profile != ("customer" if kind == "customer" else "oss")
            or not re.fullmatch(r"sha256:[0-9a-f]{64}", image)
            or ssh_host != label + ".apps." + host
            or not re.fullmatch(r"[a-z][a-z0-9-]{0,29}-" + identifier.replace("-", ""), label)
        ):
            raise ValueError("Fixture does not belong to this run")
        return cls(kind, identifier, name, image, profile, ssh_host, request)


class Acceptance:
    def __init__(self, directory: Path, stage: str) -> None:
        self.directory = directory.resolve()
        if self.directory.stat().st_mode & 0o077:
            raise ValueError("Run directory must be private (0700)")
        config = decode((self.directory / "run.json").read_text())
        self.prefix = text(config["run"])
        self.host = text(config["host"])
        self.admin = text(config["admin_alias"])
        # The host's public address is a SOPS-delivered fleet secret, so the
        # operator supplies it in the private run directory, never the repo.
        self.protected = ipaddress.IPv4Address(text(config["protected_address"]))
        self.identity = Path(text(config["identity"])).expanduser().resolve(strict=True)
        self.stage = stage
        if (
            not re.fullmatch(r"egress-[0-9]{8}(?:-[0-9]{6})?", self.prefix)
            or not re.fullmatch(r"[a-z0-9][a-z0-9.-]+", self.host)
            or not re.fullmatch(r"[a-zA-Z0-9][a-zA-Z0-9-]*", self.admin)
            or not re.fullmatch(r"[a-z0-9][a-z0-9-]{0,30}", stage)
            or not self.protected.is_global
            or not self.identity.is_file()
            or self.identity.stat().st_mode & 0o077
        ):
            raise ValueError("Invalid run configuration or private key permissions")
        self.known_hosts = self.directory / "known_hosts"
        if not self.known_hosts.is_file():
            raise ValueError("Pinned management known_hosts is required")

    def save(self, name: str, value: object) -> None:
        target = self.directory / name
        temporary = target.with_suffix(".tmp")
        with temporary.open("w") as stream:
            json.dump(value, stream, indent=2)
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(target)
        descriptor = os.open(self.directory, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)

    def run(
        self, label: str, argv: list[str], stdin: str | None = None, timeout: int = 60
    ) -> subprocess.CompletedProcess[str]:
        """@cc [owner:ghuntley,label:security;verification] egress-private-evidence
        Every attempt, including timeout and failure, MUST be durably recorded.
        Approval URLs MUST be redacted in both streams; only fixed public probe
        commands may run here, never credentials or arbitrary user payloads.
        """
        started = time.monotonic()
        process = subprocess.Popen(
            argv,
            stdin=subprocess.PIPE if stdin is not None else subprocess.DEVNULL,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
            start_new_session=True,
        )
        timed_out = False
        try:
            stdout, stderr = process.communicate(stdin, timeout=timeout)
        except subprocess.TimeoutExpired:
            # ProxyCommand descendants may retain stdout after their outer SSH
            # process dies. Kill this attempt's own session before draining it.
            with contextlib.suppress(ProcessLookupError):
                os.killpg(process.pid, signal.SIGKILL)
            stdout, stderr = process.communicate()
            timed_out = True
        redact = r'https://[^\s"<>]+/(?:ssh/)?approv[^\s"<>]*'
        stdout, stderr = (re.sub(redact, "[REDACTED]", stream) for stream in (stdout, stderr))
        record = dict(
            at=datetime.datetime.now(datetime.UTC).isoformat(),
            stage=self.stage,
            label=label,
            argv=argv,
            exit=process.returncode,
            timeout=timed_out,
            seconds=round(time.monotonic() - started, 3),
            stdout=stdout,
            stderr=stderr,
        )
        with (self.directory / "commands.jsonl").open("a") as stream:
            stream.write(json.dumps(record) + "\n")
            stream.flush()
            os.fsync(stream.fileno())
        if timed_out:
            raise TimeoutError(f"{label}: retained timed-out attempt")
        return subprocess.CompletedProcess(argv, process.returncode, stdout, stderr)

    def ssh(self, known_hosts: Path | None = None) -> list[str]:
        return [
            "ssh",
            "-4",
            "-F",
            "/dev/null",
            "-T",
            "-i",
            str(self.identity),
            "-o",
            "IdentitiesOnly=yes",
            "-o",
            "BatchMode=yes",
            "-o",
            "ConnectTimeout=10",
            "-o",
            "ServerAliveInterval=5",
            "-o",
            "ServerAliveCountMax=3",
            "-o",
            "StrictHostKeyChecking=yes",
            "-o",
            "GlobalKnownHostsFile=/dev/null",
            "-o",
            "UserKnownHostsFile=" + str(known_hosts or self.known_hosts),
        ]

    def command(self, command: str) -> dict[str, object]:
        result = self.run("management", [*self.ssh(), self.host, command])
        if result.returncode == 255:
            raise RuntimeError("Management SSH transport failed")
        # Exec lifecycle commands may print progress before their JSON envelope.
        lines = result.stdout.strip().splitlines()
        if not lines:
            raise RuntimeError("Management response has no JSON envelope")
        row = decode(lines[-1])
        if (
            result.returncode != 0
            or row.get("version") != 1
            or row.get("status") not in ("accepted", "succeeded")
        ):
            raise RuntimeError(f"Management request failed: {row.get('status')} {row.get('error')}")
        return row

    def wait(self, request: str) -> dict[str, object]:
        deadline = time.monotonic() + 600
        while time.monotonic() < deadline:
            row = self.command("request show " + shlex.quote(request) + " --json")
            if row.get("request_id") != request:
                raise RuntimeError("Request receipt does not match original intent")
            if row["status"] == "succeeded":
                return row
            time.sleep(2)
        raise TimeoutError("Request remains accepted: " + request)

    def fixture(self, kind: Kind) -> Fixture:
        return Fixture.parse(
            kind, decode((self.directory / f"vm-{kind}.json").read_text()), self.prefix, self.host
        )

    def owned(self, fixture: Fixture) -> None:
        """@cc [owner:ghuntley,label:security] egress-fixture-mutations-only
        Before stop/start/delete, the immutable UUID, pinned create receipt,
        current name, image, profile and owner MUST match this run. Name prefixes
        alone MUST NOT authorize mutations; unrelated VMs MUST remain untouched.
        """
        receipt = decode((self.directory / f"create-{fixture.kind}.json").read_text())
        if receipt.get("request_id") != fixture.request_id:
            raise ValueError("Missing matching create receipt")
        original = mapping(receipt["result"])
        current = mapping(self.command(f"show {fixture.id} --json")["result"])
        for key in ("id", "name", "image_id", "profile", "ssh_host"):
            if original.get(key) != asdict(fixture)[key] or current.get(key) != original[key]:
                raise ValueError("Fixture ownership changed: " + key)
        if current.get("owner") is not True:
            raise ValueError("Account no longer owns fixture")

    def create(self) -> None:
        identity = mapping(self.command("whoami --json")["result"])
        self.save("account.json", identity)
        images = mapping(self.command("images --json")["result"])["images"]
        if not isinstance(images, list):
            raise ValueError("Expected image list")
        catalog = [mapping(image) for image in images]
        for kind in KINDS:
            path = self.directory / f"vm-{kind}.json"
            if path.exists():
                self.wait(self.fixture(kind).request_id)
                continue
            selected = [
                image
                for image in catalog
                if text(image["name"]).startswith("Ubuntu" if kind == "ubuntu" else "NixOS")
            ]
            if len(selected) != 1:
                raise ValueError("Image selection is ambiguous")
            image = selected[0]
            minimum = image["minimum_disk_bytes"]
            if type(minimum) is not int or minimum <= 0:
                raise ValueError("Invalid minimum disk size")
            disk = max(16, (minimum + (1 << 30) - 1) // (1 << 30))
            name = self.prefix + "-" + kind
            request = name + "-create"
            memory = 2048 if kind == "nixos" else 512
            command = f"new --name {name} --image {shlex.quote(text(image['id']))} --profile {'customer' if kind == 'customer' else 'oss'} --cpu 1 --memory {memory} --disk {disk} --request-id {request} --no-wait --json"
            intent_path = self.directory / f"intent-{kind}.json"
            if intent_path.exists():
                intent = decode(intent_path.read_text())
                if intent.get("request_id") != request:
                    raise ValueError("Conflicting create intent")
                command = text(intent["command"])
            else:
                self.save(intent_path.name, dict(command=command, request_id=request))
            receipt = self.command(command)
            self.save(f"create-{kind}.json", receipt)
            fixture = Fixture.parse(
                kind, mapping(receipt["result"]) | {"request_id": request}, self.prefix, self.host
            )
            self.save(path.name, asdict(fixture))
            self.wait(request)
            print(kind + ": running", flush=True)

    def lifecycle(self, verb: Literal["stop", "start", "rm"], kind: Kind) -> None:
        fixture = self.fixture(kind)
        request = f"{self.prefix}-{kind}-{self.stage}-{verb}"
        outcome = {"stop": "stopped", "start": "running", "rm": "deleted"}[verb]
        completed = f"{self.stage}-{kind}-{verb}-completed.json"
        admitted = f"{self.stage}-{kind}-{verb}.json"
        if (self.directory / completed).exists():
            receipt = decode((self.directory / completed).read_text())
            if (
                receipt.get("request_id") != request
                or receipt.get("status") != "succeeded"
                or mapping(receipt["result"]).get("id") != fixture.id
                or mapping(receipt["result"]).get("outcome") != outcome
            ):
                raise ValueError("Conflicting completed lifecycle receipt")
            return
        if (self.directory / admitted).exists():
            receipt = decode((self.directory / admitted).read_text())
            if (
                receipt.get("request_id") != request
                or mapping(receipt["result"]).get("id") != fixture.id
            ):
                raise ValueError("Conflicting admitted lifecycle receipt")
            self.complete(request, fixture.id, outcome, completed)
            return
        self.owned(fixture)
        command = f"{verb} {fixture.id} --request-id {request} --no-wait --json"
        self.save(
            f"{self.stage}-{kind}-{verb}-intent.json", dict(command=command, request_id=request)
        )
        self.save(admitted, self.command(command))
        self.complete(request, fixture.id, outcome, completed)

    def complete(self, request: str, identifier: str, outcome: str, filename: str) -> None:
        receipt = self.wait(request)
        result = mapping(receipt["result"])
        if result.get("id") != identifier or result.get("outcome") != outcome:
            raise RuntimeError("Unexpected lifecycle outcome")
        self.save(filename, receipt)

    def public(self, url: str) -> str:
        """@cc [owner:ghuntley,label:security;verification] egress-public-get-retries
        Only transient GET failures may retry, at most three attempts. Every
        failure MUST remain recorded; TLS certificate refusal MUST fail without
        retry. Successful bytes still require caller trust/identity validation.
        """
        # Retry only bounded transient GET failures. run() retains every attempt;
        # successful bytes still pass the caller's exact trust/reference checks.
        for attempt in range(3):
            result = self.run(
                "public-reference",
                ["curl", "--noproxy", "*", "--http1.1", "-fsS", "--max-time", "20", url],
            )
            if result.returncode == 0:
                return result.stdout
            if result.returncode not in (22, 28, 35, 56):
                raise RuntimeError("Public reference unavailable")
            if attempt == 2:
                raise PublicReferenceUnavailable("Public reference unavailable")
            time.sleep(2)
        raise RuntimeError("Public reference unavailable")

    def guest(
        self, fixture: Fixture, script: str, timeout: int = 240
    ) -> subprocess.CompletedProcess[str]:
        trust = decode(self.public(f"https://{self.host}/bin/ssh-trust.json"))
        if trust.get("management_host") != self.host or trust.get("zone") != "apps." + self.host:
            raise ValueError("Unexpected SSH trust scope")
        ca = text(trust["ca"])
        if not re.fullmatch(r"ssh-ed25519 [A-Za-z0-9+/=]+", ca):
            raise ValueError("Invalid SSH CA")
        known = self.directory / "guest-known-hosts"
        policy = f"@cert-authority *.apps.{self.host},audi-*.ssh.{self.host} {ca}\n"
        if known.exists() and known.read_text() != policy:
            raise ValueError("SSH CA changed during this run; reconcile trust independently")
        known.write_text(policy)
        label = fixture.ssh_host.split(".")[0]
        fields = self.public(f"https://{self.host}/api/audi/v1/known-hosts/{label}").split()
        if len(fields) != 3 or fields[:2] != [fixture.ssh_host, "ssh-ed25519"]:
            raise ValueError("Unexpected gateway key")
        blob = base64.b64decode(fields[2], validate=True)
        if len(blob) != 51 or not blob.startswith(b"\x00\x00\x00\x0bssh-ed25519\x00\x00\x00\x20"):
            raise ValueError("Invalid gateway Ed25519 wire key")
        alias = (
            "audi-"
            + base64.b32encode(hashlib.sha256(blob).digest()).decode().lower().rstrip("=")
            + ".ssh."
            + self.host
        )
        ssh = [*self.ssh(known), "-o", "HostKeyAlgorithms=ssh-ed25519-cert-v01@openssh.com"]
        proxy = shlex.join(
            [*ssh, "-o", "HostKeyAlias=" + alias, "audi@" + fixture.ssh_host, "connect", label]
        )
        account = decode((self.directory / "account.json").read_text())
        username = text(account["guest_username"])
        if not re.fullmatch(r"[a-z_][a-z0-9_.-]{0,30}", username) or username == "root":
            raise ValueError("Invalid account username")
        return self.run(
            f"guest-{fixture.kind}",
            [*ssh, "-o", "ProxyCommand=" + proxy, username + "@" + fixture.ssh_host, "sh -se"],
            script,
            timeout=timeout,
        )

    def probe(self) -> None:
        started = datetime.datetime.now(datetime.UTC).strftime("%Y-%m-%d %H:%M:%S UTC")
        reference = self.public(ARTIFACT)
        digest = hashlib.sha256(reference.encode()).hexdigest()
        public_ip = socket.gethostbyname("cdn.jsdelivr.net")
        control = self.run(
            "public-ip-control",
            [
                "curl",
                "--noproxy",
                "*",
                "--http1.1",
                "--resolve",
                f"cdn.jsdelivr.net:443:{public_ip}",
                "-fsS",
                "--max-time",
                "20",
                ARTIFACT,
            ],
        )
        if control.returncode != 0 or hashlib.sha256(control.stdout.encode()).hexdigest() != digest:
            raise RuntimeError(
                "Pinned public destination control failed; refusal cannot be established"
            )
        self.save(f"{self.stage}-reference.json", dict(url=ARTIFACT, sha256=digest, ipv4=public_ip))
        results: dict[str, str] = {}
        for kind in KINDS:
            fixture = self.fixture(kind)
            if kind == "customer":
                script = f"""set -eu
if curl --noproxy '*' --resolve cdn.jsdelivr.net:443:{public_ip} --connect-timeout 4 --max-time 8 -fsS {ARTIFACT} -o /dev/null; then
  echo unexpected-customer-egress; exit 1
else
  status=$?; test "$status" = 7 -o "$status" = 28
  echo customer-tcp-denied
fi
"""
            else:
                script = f"""set -eu
work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
curl --noproxy '*' --max-time 30 -fsS {ARTIFACT} -o "$work/public"
test "$(sha256sum "$work/public" | cut -d ' ' -f 1)" = {digest}
curl --noproxy '*' --max-time 30 -fsS {ARTIFACT} -o "$work/repeated"
cmp "$work/public" "$work/repeated"
curl --noproxy '*' --max-time 30 -fsSL https://github.com/octocat/Hello-World/raw/master/README -o "$work/redirect"
test -s "$work/redirect"
GIT_TERMINAL_PROMPT=0 git clone -q --depth 1 https://github.com/octocat/Hello-World.git "$work/repo"
test "$(git -C "$work/repo" rev-parse --is-shallow-repository)" = true
git -C "$work/repo" rev-parse HEAD
curl --noproxy '*' --max-time 30 -fsS {ARTIFACT} -o /dev/null -w '%{{ssl_verify_result}}\\n%{{certs}}' > "$work/chain"
grep -x 0 "$work/chain"
grep '^Issuer:.*Overalls Brady' "$work/chain"
for ip in 10.90.0.1 169.254.169.254 {self.protected}; do
  if curl --noproxy '*' --connect-timeout 2 --max-time 3 -fsS "http://$ip/" -o /dev/null; then
    echo unexpected-protected-access; exit 1
  else
    status=$?; test "$status" = 7 -o "$status" = 28 -o "$status" = 56
  fi
done
echo verified-https-redirect-clone-repeat-protected
"""
            outcome = self.guest(fixture, script)
            if outcome.returncode != 0:
                raise RuntimeError(
                    f"{kind}: probe failed ({outcome.returncode}); see private evidence"
                )
            marker = (
                "customer-tcp-denied"
                if kind == "customer"
                else "verified-https-redirect-clone-repeat-protected"
            )
            if marker not in outcome.stdout:
                raise RuntimeError("Missing completed guest probe")
            results[kind] = "passed"
            print(kind + ": passed", flush=True)
        journal = self.run(
            "probe-events",
            [
                "ssh",
                self.admin,
                "sudo -n journalctl -u brady.service --since "
                + shlex.quote(started)
                + " -o cat --no-pager",
            ],
        )
        if journal.returncode != 0:
            raise RuntimeError("Cannot verify proxy evidence")
        events: list[dict[str, object]] = []
        for line in journal.stdout.splitlines():
            try:
                events.append(decode(line))
            except (ValueError, json.JSONDecodeError):
                continue
        owner = decode((self.directory / "account.json").read_text())["id"]
        for kind in ("nixos", "ubuntu"):
            fixture = self.fixture(kind)
            current = mapping(self.command(f"show {fixture.id} --json")["result"])
            generation = current.get("generation")
            if type(generation) is not int or generation <= 0:
                raise RuntimeError("Missing current execution generation")
            rows = [
                event
                for event in events
                if event.get("vm_id") == fixture.id
                and event.get("owner_id") == owner
                and event.get("attribution") == "resolved"
                and event.get("protocol") == "https"
                and event.get("reason") == "ok"
                and event.get("generation") == generation
            ]
            if not rows or not any(
                event.get("cache") == "hit" and event.get("bytes_sent") == len(reference.encode())
                for event in rows
            ):
                raise RuntimeError(kind + ": missing current resolved HTTPS/cache-hit evidence")
        self.save(f"{self.stage}-probes.json", results)
        self.save(f"{self.stage}-proxy-evidence.json", events)

    def archive(self) -> None:
        """@cc [owner:ghuntley,label:verification] egress-real-flake-cache
        The real pinned archive MUST match an independent streamed digest; Nix
        fetches MUST use separate stores/download caches and match the locked NAR
        hash. Local Nix reuse MUST NOT count as an attributed proxy cache hit.
        """
        locked = mapping(
            mapping(
                decode((Path(__file__).resolve().parent.parent / "flake.lock").read_text())["nodes"]
            )["nixpkgs"]
        )
        pin = mapping(locked["locked"])
        revision, nar_hash = text(pin["rev"]), text(pin["narHash"])
        if (
            pin.get("owner") != "NixOS"
            or pin.get("repo") != "nixpkgs"
            or not re.fullmatch(r"[0-9a-f]{40}", revision)
        ):
            raise ValueError("Unexpected nixpkgs pin")
        if (
            not nar_hash.startswith("sha256-")
            or len(base64.b64decode(nar_hash[7:], validate=True)) != 32
        ):
            raise ValueError("Invalid locked NAR hash")
        url = "https://codeload.github.com/NixOS/nixpkgs/legacy.tar.gz/" + revision
        reference_name = f"{self.stage}-archive-reference.json"
        reference_path = self.directory / reference_name
        if reference_path.exists():
            reference = decode(reference_path.read_text())
            if reference.get("revision") != revision or reference.get("nar_hash") != nar_hash:
                raise ValueError("Conflicting archive reference")
            digest, size = text(reference["sha256"]), reference["bytes"]
            if not re.fullmatch(r"[0-9a-f]{64}", digest) or type(size) is not int or size <= 0:
                raise ValueError("Invalid archive reference")
        else:
            digest_state, size = hashlib.sha256(), 0
            with urllib.request.urlopen(url, timeout=60) as response:
                while chunk := response.read(65536):
                    digest_state.update(chunk)
                    size += len(chunk)
            digest = digest_state.hexdigest()
            self.save(
                reference_name,
                dict(url=url, revision=revision, nar_hash=nar_hash, sha256=digest, bytes=size),
            )
        results: dict[str, str] = {}
        for kind in ("nixos", "ubuntu"):
            fixture = self.fixture(kind)
            self.owned(fixture)
            started = datetime.datetime.now(datetime.UTC).isoformat()
            script = f"""set -eu
work=$(mktemp -d)
trap 'sudo -n rm -rf "$work"' EXIT
for pass in 1 2; do
  echo archive-fetch-$pass-start
  curl --noproxy '*' --max-time 180 -fsS {shlex.quote(url)} -o "$work/archive"
  test "$(stat -c %s "$work/archive")" = {size}
  test "$(sha256sum "$work/archive" | cut -d ' ' -f 1)" = {digest}
  echo archive-fetch-$pass-verified
done
echo archive-exact-bytes
"""
            outcome = self.guest(fixture, script, timeout=900)
            if outcome.returncode != 0 or "archive-exact-bytes" not in outcome.stdout:
                raise RuntimeError(kind + ": archive acceptance failed; retained private evidence")
            rows = self.archive_rows(fixture, started, size)
            self.save(f"{self.stage}-{kind}-archive-events.json", rows)
            if kind == "nixos":
                # Nix 2.34's GitHub fetcher redirects /archive/REV.tar.gz to
                # codeload /tar.gz/REV; its root prefix differs from legacy.
                nix_url = "https://codeload.github.com/NixOS/nixpkgs/tar.gz/" + revision
                nix_reference_name = f"{self.stage}-nix-archive-reference.json"
                nix_reference_path = self.directory / nix_reference_name
                if nix_reference_path.exists():
                    nix_reference = decode(nix_reference_path.read_text())
                    if nix_reference.get("url") != nix_url:
                        raise ValueError("Conflicting Nix archive representation")
                    nix_size = nix_reference["bytes"]
                    if type(nix_size) is not int or nix_size <= 0:
                        raise ValueError("Invalid Nix wire size")
                else:
                    nix_digest, nix_size = hashlib.sha256(), 0
                    with urllib.request.urlopen(nix_url, timeout=60) as response:
                        while chunk := response.read(65536):
                            nix_digest.update(chunk)
                            nix_size += len(chunk)
                    self.save(
                        nix_reference_name,
                        dict(url=nix_url, bytes=nix_size, sha256=nix_digest.hexdigest()),
                    )
                nix_started = datetime.datetime.now(datetime.UTC).isoformat()
                nix_script = f"""set -eu
command -v nix >/dev/null
work=$(mktemp -d)
trap 'sudo -n rm -rf "$work"' EXIT
for pass in 1 2; do
  mkdir -p "$work/home$pass" "$work/cache$pass"
  sudo -n env HOME="$work/home$pass" XDG_CACHE_HOME="$work/cache$pass" NIX_USER_CONF_FILES=/dev/null \
    nix --extra-experimental-features 'nix-command flakes' --store "local?root=$work/store$pass" \
    flake metadata --json --no-write-lock-file github:NixOS/nixpkgs/{revision} > "$work/flake$pass.json"
  cat "$work/flake$pass.json"
  echo
  sudo -n rm -rf "$work/home$pass" "$work/cache$pass" "$work/store$pass"
done
echo isolated-flakes-complete
"""
                nix_result = self.guest_job(fixture, nix_script, "flakes")
                if (
                    nix_result.returncode != 0
                    or "isolated-flakes-complete" not in nix_result.stdout
                ):
                    raise RuntimeError(
                        "Actual isolated flake fetch failed; retained private evidence"
                    )
                flakes = [
                    decode(line) for line in nix_result.stdout.splitlines() if line.startswith("{")
                ]
                if len(flakes) != 2:
                    raise ValueError("Missing independent Nix fetches")
                for flake in flakes:
                    observed = mapping(flake["locked"])
                    if observed.get("rev") != revision or observed.get("narHash") != nar_hash:
                        raise ValueError("Nix locked identity differs")
                # Separate request window: curl hits cannot satisfy Nix reuse.
                nix_rows = self.archive_rows(fixture, nix_started, nix_size)
                self.save(f"{self.stage}-nixos-flake-events.json", nix_rows)
            results[kind] = "passed"
            print(
                kind
                + ": archive"
                + (" and isolated flakes" if kind == "nixos" else "")
                + " passed",
                flush=True,
            )
        self.save(f"{self.stage}-archive-results.json", results)

    def archive_rows(self, fixture: Fixture, started: str, size: int) -> list[dict[str, object]]:
        """@cc [owner:ghuntley,label:verification] egress-archive-request-window
        Each two-fetch window MUST have two exact-size current-owner/generation
        HTTPS completions and at least one hit. Hits from a different window or
        encoding variant MUST NOT establish isolated Nix fetch reuse.
        """
        journal = self.run(
            "archive-events-" + fixture.kind,
            [
                "ssh",
                self.admin,
                "sudo -n journalctl -u brady.service --since "
                + shlex.quote(started)
                + " -o cat --no-pager",
            ],
        )
        if journal.returncode != 0:
            raise RuntimeError("Missing archive request evidence")
        events: list[dict[str, object]] = []
        for line in journal.stdout.splitlines():
            try:
                events.append(decode(line))
            except (ValueError, json.JSONDecodeError):
                continue
        owner = decode((self.directory / "account.json").read_text())["id"]
        current = mapping(self.command(f"show {fixture.id} --json")["result"])
        generation = current.get("generation")
        if type(generation) is not int or generation <= 0:
            raise ValueError("Missing current execution generation")
        rows = [
            event
            for event in events
            if event.get("vm_id") == fixture.id
            and event.get("owner_id") == owner
            and event.get("attribution") == "resolved"
            and event.get("generation") == generation
            and event.get("protocol") == "https"
            and event.get("reason") == "ok"
            and event.get("status") == 200
            and event.get("bytes_sent") == size
        ]
        if len(rows) < 2 or not any(event.get("cache") == "hit" for event in rows):
            raise RuntimeError(fixture.kind + ": missing actual attributed archive reuse")
        return rows

    def large(self) -> None:
        self.large_artifact(
            "https://codeload.github.com/llvm/llvm-project/legacy.tar.gz/"
            "1d07d16b78398848041e650d919d634c782e8309",
            200 * 1024**2,
            512 * 1024**2,
            300,
            900,
        )

    def large4gib(self) -> None:
        # Published checkpoint: google-research/big_vision SigLIP 2, CC-BY 4.0.
        # Explicit public freshness, anonymous query-free HTTPS; no exception.
        self.large_artifact(
            "https://storage.googleapis.com/big_vision/siglip2/siglip2_g-opt16_384.npz",
            4 * 1024**3,
            16 * 1024**3,
            1200,
            3000,
        )

    def large_artifact(
        self, url: str, minimum: int, maximum: int, transfer_timeout: int, job_timeout: int
    ) -> None:
        """@cc [owner:ghuntley,label:verification] egress-live-large-proof
        A public artifact MUST match an independent bounded streaming digest and
        be reused by both current owned guests. Missing exact-size attributed hits
        or changed reference bytes MUST fail regardless of successful forwarding.
        Replays MUST retain the original guest request window and artifact identity;
        cleanup or receipt collection MUST NOT create a fresh proof window.
        """
        path = self.directory / (self.stage + "-large-reference.json")
        reference = self.artifact_reference(url, minimum, maximum)
        if path.exists() and decode(path.read_text()) != reference:
            raise ValueError("Public artifact identity changed before acceptance")
        self.save(path.name, reference)
        expected, size = text(reference["sha256"]), reference["bytes"]
        if type(size) is not int:
            raise ValueError("Invalid artifact size")
        for kind in ("nixos", "ubuntu"):
            fixture = self.fixture(kind)
            self.owned(fixture)
            window_name = f"{self.stage}-large-{kind}-window.json"
            window_path = self.directory / window_name
            if window_path.exists():
                window = decode(window_path.read_text())
                if (
                    window.get("vm_id") != fixture.id
                    or window.get("reference") != reference
                    or window.get("job_timeout") != job_timeout
                ):
                    raise ValueError("Conflicting retained artifact request window")
                started = text(window["started"])
                at = datetime.datetime.fromisoformat(started)
                if at.tzinfo != datetime.UTC or at > datetime.datetime.now(datetime.UTC):
                    raise ValueError("Invalid retained artifact request window")
            else:
                started = datetime.datetime.now(datetime.UTC).isoformat()
                self.save(
                    window_name,
                    dict(
                        vm_id=fixture.id,
                        reference=reference,
                        job_timeout=job_timeout,
                        started=started,
                    ),
                )
            script = f"""set -eu
work=$(mktemp -d "$HOME/.overalls-egress-large-XXXXXXXX")
trap 'rm -rf "$work"' EXIT
available=$(df -B1 --output=avail "$work" | tail -1)
test "$available" -gt {size + 512 * 1024**2}
for pass in 1 2; do
  echo large-fetch-$pass-start
  curl --noproxy '*' --max-time {transfer_timeout} -fsS {shlex.quote(url)} -o "$work/body"
  test "$(stat -c %s "$work/body")" = {size}
  test "$(sha256sum "$work/body" | cut -d ' ' -f 1)" = {expected}
  echo large-fetch-$pass-verified
done
echo large-exact-bytes
"""
            result = self.guest_job(fixture, script, "large", job_timeout)
            if result.returncode != 0 or "large-exact-bytes" not in result.stdout:
                raise RuntimeError("Large exact-byte acceptance failed")
            rows = self.archive_rows(fixture, started, size)
            self.save(f"{self.stage}-large-{kind}.json", rows)
            print(f"{kind}: {size} exact bytes and reuse passed", flush=True)
        if self.artifact_reference(url, minimum, maximum) != reference:
            raise ValueError("Public artifact identity changed after acceptance")
        self.save(f"{self.stage}-large-results.json", dict(outcome="passed", bytes=size))

    @staticmethod
    def artifact_reference(url: str, minimum: int, maximum: int) -> dict[str, object]:
        """@cc [owner:ghuntley,label:verification] egress-artifact-stream-bound
        Independent artifact references MUST hash bounded chunks, refuse outside
        the specified size interval and terminate within a fixed total deadline.
        Redirected or mismatched bytes MUST NOT inherit an earlier identity.
        """
        state, size = hashlib.sha256(), 0
        deadline = time.monotonic() + 1200
        with urllib.request.urlopen(url, timeout=60) as response:
            if response.geturl() != url:
                raise ValueError("Public artifact redirect changed reference scope")
            while chunk := response.read(65536):
                state.update(chunk)
                size += len(chunk)
                if size > maximum or time.monotonic() > deadline:
                    raise ValueError("Independent artifact exceeds fixture bounds")
        if not minimum <= size <= maximum:
            raise ValueError("Public artifact does not cover the large-file case")
        return dict(url=url, bytes=size, sha256=state.hexdigest())

    def guest_job(
        self, fixture: Fixture, script: str, purpose: str, job_timeout: int = 900
    ) -> subprocess.CompletedProcess[str]:
        """@cc [owner:ghuntley,label:verification;security] egress-durable-guest-job
        Long checks MUST remain confined to a currently owned fixture and one
        deterministic private job path. Replays MUST match the exact script.
        Retained receipts MUST match its fingerprint and bounded output/status;
        a completed receipt MUST resume cleanup without relaunching the job.
        Only an atomic bounded exit receipt establishes completion; transport
        failure or elapsed time MUST NOT establish success.
        """
        if type(job_timeout) is not int or not 60 <= job_timeout <= 3600:
            raise ValueError("Invalid bounded guest job timeout")
        self.owned(fixture)
        identifier = uuid.uuid5(
            uuid.NAMESPACE_URL,
            "/".join((self.prefix, self.stage, fixture.id, purpose, str(job_timeout))),
        )
        directory = "/tmp/overalls-egress-job-" + str(identifier)
        encoded = base64.b64encode(script.encode()).decode("ascii")
        digest = hashlib.sha256(script.encode()).hexdigest()
        receipt_name = f"{self.stage}-{fixture.kind}-{purpose}-job.json"
        receipt_path = self.directory / receipt_name
        if receipt_path.exists():
            if receipt_path.stat().st_size > 131072:
                raise ValueError("Retained job receipt exceeds bound")
            receipt = decode(receipt_path.read_text())
            status, output = receipt.get("exit"), receipt.get("output")
            if (
                receipt.get("id") != str(identifier)
                or receipt.get("script_sha256") != digest
                or type(status) is not int
                or not 0 <= status <= 255
                or not isinstance(output, str)
                or len(output.encode()) > 16384
            ):
                raise ValueError("Retained job receipt identity or shape unconfirmed")
            self.cleanup_guest_job(fixture, identifier)
            return subprocess.CompletedProcess(
                ["retained-guest-job", str(identifier)], status, output, ""
            )
        kickoff = f"""set -eu
job={shlex.quote(directory)}
umask 077
if mkdir "$job" 2>/dev/null; then
  printf %s {shlex.quote(encoded)} | base64 -d > "$job/script"
else
  test -d "$job" && test ! -L "$job" && test "$(stat -c %u "$job")" = "$(id -u)"
  test "$(sha256sum "$job/script" | cut -d ' ' -f 1)" = {digest}
fi
if mkdir "$job/started" 2>/dev/null; then
  nohup sh -c 'timeout {job_timeout - 50} sh "$1/script" > "$1/output" 2>&1; status=$?; printf %s "$status" > "$1/status.tmp"; mv "$1/status.tmp" "$1/status"' acceptance-job "$job" >/dev/null 2>&1 </dev/null &
fi
echo acceptance-job-started
"""
        for attempt in range(3):
            try:
                started = self.guest(fixture, kickoff)
            except PublicReferenceUnavailable:
                if attempt == 2:
                    raise
                time.sleep(5)
                self.owned(fixture)
                continue
            if started.returncode == 0 and "acceptance-job-started" in started.stdout:
                break
            if started.returncode not in (254, 255) or attempt == 2:
                raise RuntimeError("Guest job launch unconfirmed; preserve its deterministic path")
            time.sleep(5)
            self.owned(fixture)
        deadline = time.monotonic() + job_timeout
        poll = f"""set -eu
job={shlex.quote(directory)}
test -d "$job" && test ! -L "$job" && test "$(stat -c %u "$job")" = "$(id -u)"
test "$(sha256sum "$job/script" | cut -d ' ' -f 1)" = {digest}
if test -f "$job/status"; then
  printf 'job-exit:'; cat "$job/status"; echo
  test "$(stat -c %s "$job/output")" -le 16384
  cat "$job/output"
else
  echo job-pending
fi
"""
        while time.monotonic() < deadline:
            try:
                result = self.guest(fixture, poll)
            except PublicReferenceUnavailable:
                # Route/readiness refusal cannot grant trust or complete a job.
                # Revalidate ownership before another read of its original receipt.
                time.sleep(5)
                self.owned(fixture)
                continue
            if result.returncode != 0:
                if result.returncode in (254, 255):
                    # Each unconfirmed channel attempt is retained by run(). A new
                    # authorized read may collect the original atomic receipt.
                    time.sleep(5)
                    self.owned(fixture)
                    continue
                raise RuntimeError("Guest job receipt unavailable; preserve evidence")
            lines = result.stdout.splitlines()
            if lines and re.fullmatch(r"job-exit:(0|[1-9][0-9]{0,2})", lines[0]):
                status = int(lines[0].split(":")[1])
                if status > 255:
                    raise ValueError("Invalid guest exit receipt")
                self.save(
                    receipt_name,
                    dict(
                        id=str(identifier),
                        script_sha256=digest,
                        exit=status,
                        output="\n".join(lines[1:]),
                    ),
                )
                self.cleanup_guest_job(fixture, identifier)
                return subprocess.CompletedProcess(
                    result.args, status, "\n".join(lines[1:]), result.stderr
                )
            if result.stdout.strip() != "job-pending":
                raise ValueError("Malformed guest completion receipt")
            time.sleep(5)
        raise TimeoutError("Guest job remains incomplete; retain its original path")

    def cleanup_guest_job(self, fixture: Fixture, identifier: uuid.UUID) -> None:
        """@cc [owner:ghuntley,label:security;verification] egress-job-cleanup-replay
        Cleanup MUST target only the exact deterministic private job path in a
        currently owned fixture. Unconfirmed channel outcomes may retry the same
        deletion at most five times; they MUST NOT relaunch a completed job.
        """
        directory = "/tmp/overalls-egress-job-" + str(identifier)
        for attempt in range(5):
            self.owned(fixture)
            try:
                cleanup = self.guest(fixture, "rm -rf -- " + shlex.quote(directory))
            except PublicReferenceUnavailable:
                if attempt == 4:
                    raise
                time.sleep(5)
                continue
            if cleanup.returncode == 0:
                return
            if cleanup.returncode not in (254, 255) or attempt == 4:
                raise RuntimeError("Guest job cleanup unconfirmed")
            time.sleep(5)

    def snapshot(self) -> None:
        # Only public updater state and closed proxy events/counters; never unit environments.
        for label, command in {
            "updater": "sudo -n cat /var/lib/overalls-auto-update/status.json",
            "metrics": "sudo -n cat /run/brady/metrics.json /run/brady-pressure/pressure.json",
            "events": "sudo -n journalctl -u brady.service --since '20 minutes ago' -o cat --no-pager",
            "network": "sudo -n sh -c 'ns=$(systemctl show brady -p NetworkNamespacePath --value); ip netns exec ${ns##*/} nft list chain inet lilly_filter brady_intercept'",
        }.items():
            outcome = self.run(label, ["ssh", self.admin, command])
            if outcome.returncode != 0:
                raise RuntimeError("Snapshot failed: " + label)
            self.save(f"{self.stage}-{label}.json", dict(stdout=outcome.stdout))


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("directory", type=Path)
    parser.add_argument(
        "phase",
        choices=[
            "create",
            "probe",
            "archive",
            "large",
            "large4gib",
            "snapshot",
            "restart",
            "cleanup",
        ],
    )
    parser.add_argument("--stage", default="baseline")
    args = parser.parse_args()
    runner = Acceptance(args.directory, args.stage)
    match args.phase:
        case "create":
            runner.create()
        case "probe":
            runner.probe()
        case "archive":
            runner.archive()
        case "large":
            runner.large()
        case "large4gib":
            runner.large4gib()
        case "snapshot":
            runner.snapshot()
        case "restart":
            for kind in KINDS:
                runner.lifecycle("stop", kind)
                runner.lifecycle("start", kind)
        case "cleanup":
            for kind in KINDS:
                runner.lifecycle("rm", kind)


if __name__ == "__main__":
    main()
