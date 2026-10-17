"""Verify real native services against an isolated HTTPS/SSH authority."""

from __future__ import annotations

import argparse
import hashlib
import ipaddress
import json
import os
import re
import secrets
import shlex
import shutil
import signal
import ssl
import stat
import subprocess
import threading
import time
from collections.abc import Callable
from dataclasses import dataclass, replace
from functools import partial
from pathlib import Path

import native_control as control
import native_git_fixture as git_fixture
import native_growth_oracle as growth_oracle
import native_omnios_growth_oracle as omnios_growth_oracle
import native_services as services

PRINCIPAL = "native.fixture.test"
USERNAME = "u200000"


@dataclass(frozen=True)
class Network:
    """Validated synthetic identity supplied by the isolated host harness."""

    address: str
    gateway: str
    mac: str

    def __post_init__(self) -> None:
        for value in (self.address, self.gateway):
            address = ipaddress.IPv4Address(value)
            if str(address) != value or address.is_multicast or address.is_unspecified:
                raise ValueError("invalid native fixture network identity")
        if self.address == self.gateway or re.fullmatch(r"02(?::[0-9a-f]{2}){5}", self.mac) is None:
            raise ValueError("invalid native fixture network identity")


DEFAULT_NETWORK = Network("10.10.0.203", "10.10.0.1", "02:fc:0a:00:00:cb")


@dataclass(frozen=True)
class Platform:
    """Closed native command dialect; no caller-supplied command paths."""

    name: services.Os

    def __post_init__(self) -> None:
        if self.name not in ("freebsd", "illumos"):
            raise ValueError("invalid native fixture platform")

    @property
    def bash(self) -> str:
        return "/usr/local/bin/bash" if self.name == "freebsd" else "/bin/bash"

    @property
    def sudo(self) -> str:
        return "/usr/local/bin/sudo" if self.name == "freebsd" else "/usr/bin/sudo"

    @property
    def git(self) -> str:
        return "/usr/local/bin/git" if self.name == "freebsd" else "/usr/bin/git"

    @property
    def home(self) -> str:
        return "/home/u200000" if self.name == "freebsd" else "/export/home/u200000"

    @property
    def shutdown(self) -> str:
        return "/sbin/shutdown -p now" if self.name == "freebsd" else "/usr/sbin/poweroff"


@dataclass(frozen=True)
class BootContext:
    """Private in-process capability for a separately maintained machine oracle."""

    uds: Path
    boot: services.Boot
    fixture: Path
    work: Path
    network: Network
    platform: Platform
    process: subprocess.Popen[bytes]
    authority: control.Authority
    api: Path | None = None


def firecracker_arguments(vmm: Path, metadata: Path, config: Path, api: Path | None) -> list[str]:
    """Select only the default no-API mode or a fixed local test socket."""
    control = ["--no-api"] if api is None else ["--api-sock", str(api)]
    return [
        str(vmm),
        "--enable-pci",
        *control,
        "--metadata",
        str(metadata),
        "--config-file",
        str(config),
    ]


def prepare_api_socket(api: Path | None, previous: subprocess.Popen[bytes] | None) -> None:
    """@cc [owner:ghuntley,label:verification;security] native-test-api-socket-lifetime
    An enabled test API MUST use one Unix socket inside the private work root.
    Cleanup MUST refuse while the preceding VM lives and MUST unlink only the
    test user's actual socket. Links, files and foreign-owned paths MUST refuse.
    The default no-API path MUST perform no API filesystem access.
    """
    if api is None:
        return
    if previous is not None and previous.poll() is None:
        raise RuntimeError("cannot replace the API socket of a live native VM")
    try:
        metadata = api.lstat()
    except FileNotFoundError:
        return
    if not stat.S_ISSOCK(metadata.st_mode) or metadata.st_uid != os.geteuid():
        raise ValueError("native test API cleanup requires the owned Unix socket")
    api.unlink()


def digest(path: Path) -> str:
    with path.open("rb") as source:
        return hashlib.file_digest(source, "sha256").hexdigest()


def alive(process: subprocess.Popen[bytes]) -> None:
    if process.poll() is not None:
        raise RuntimeError("native service VM exited unexpectedly")


def wait_kernel(
    process: subprocess.Popen[bytes],
    uds: Path,
    binding: services.Binding,
    expected: str,
    platform: Platform,
) -> services.Boot:
    deadline = time.monotonic() + 240
    while True:
        alive(process)
        try:
            return services.kernel_boot(uds, binding, platform.name, expected)
        except (OSError, services.ProtocolError):
            if time.monotonic() >= deadline:
                raise RuntimeError("native service boot deadline exceeded") from None
            time.sleep(0.5)


def wait_readiness(process: subprocess.Popen[bytes], uds: Path, boot: services.Boot) -> None:
    deadline = time.monotonic() + 90
    while True:
        alive(process)
        try:
            if services.readiness(uds, boot.binding) != boot:
                raise RuntimeError("native readiness changed boot identity")
            return
        except (OSError, services.ProtocolError):
            if time.monotonic() >= deadline:
                raise RuntimeError("native complete readiness deadline exceeded") from None
            time.sleep(0.5)


def ssh(
    fixture: Path,
    known_hosts: Path,
    command: str | None,
    *,
    user: str = USERNAME,
    key: str = "user",
    options: tuple[str, ...] = (),
    network: Network = DEFAULT_NETWORK,
) -> subprocess.CompletedProcess[bytes]:
    """Run fixed synthetic probes without emitting commands or output."""
    arguments = [
        "ssh",
        "-F",
        "/dev/null",
        "-T",
        "-i",
        str(fixture / key),
        "-o",
        "IdentitiesOnly=yes",
        "-o",
        "BatchMode=yes",
        "-o",
        "ConnectTimeout=3",
        "-o",
        "ConnectionAttempts=1",
        "-o",
        "StrictHostKeyChecking=yes",
        "-o",
        "GlobalKnownHostsFile=/dev/null",
        "-o",
        f"UserKnownHostsFile={known_hosts}",
        "-o",
        f"HostKeyAlias={PRINCIPAL}",
        "-o",
        "HostKeyAlgorithms=ssh-ed25519-cert-v01@openssh.com",
        "-o",
        "LogLevel=ERROR",
        *options,
        f"{user}@{network.address}",
    ]
    if command is not None:
        arguments.append(command)
    result = subprocess.run(
        arguments, stdin=subprocess.DEVNULL, capture_output=True, check=False, timeout=20
    )
    if len(result.stdout) > 4096 or len(result.stderr) > 4096:
        raise RuntimeError("native SSH probe exceeded its output bound")
    return result


def success(result: subprocess.CompletedProcess[bytes], expected: bytes) -> None:
    if result.returncode != 0 or result.stdout != expected:
        failure = "other"
        for marker, category in (
            (b"Connection timed out", "connect-timeout"),
            (b"Connection refused", "connect-refused"),
            (b"Permission denied", "authorization-refused"),
            (b"Host key verification failed", "host-certificate-refused"),
            (b"Connection closed", "connection-closed"),
            (b"Connection reset", "connection-reset"),
        ):
            if marker in result.stderr:
                failure = category
                break
        print(
            f"native SSH closed result mismatch: status={result.returncode} "
            f"stdout_bytes={len(result.stdout)} stderr_bytes={len(result.stderr)} failure={failure}",
            flush=True,
        )
        raise RuntimeError("native SSH did not produce its closed expected result")


def refused(result: subprocess.CompletedProcess[bytes]) -> None:
    if result.returncode == 0 or result.stdout:
        raise RuntimeError("native SSH answered a refused operation")


def ssh_checks(
    fixture: Path, work: Path, authority: control.Authority, network: Network, platform: Platform
) -> str:
    """@cc [owner:ghuntley,label:verification;security] native-ssh-real-session-evidence
    SSH checks MUST exercise real sshd, certified host keys, managed accounts,
    Bash and sudo. Session refusal MUST permit key authorization while denying
    the private login receipt and attempting startup files/client environment
    overrides. A refused session MUST execute no user bytes.
    """
    probe = partial(ssh, network=network)
    known_hosts = work / "known_hosts"
    known_hosts.write_text(
        f"@cert-authority {PRINCIPAL} {(fixture / 'ssh-ca.pub').read_text().strip()}\n"
    )
    success(
        probe(
            fixture,
            known_hosts,
            "set -eu; /usr/bin/id -u; /usr/bin/id -g; printf '%s\\n' \"$SHELL\"; "
            f"{platform.sudo} -n /usr/bin/id -u",
        ),
        f"200000\n200000\n{platform.bash}\n0\n".encode("ascii"),
    )
    print("native SSH managed identity and sudo verified", flush=True)
    refused(probe(fixture, known_hosts, "printf refused", key="wrong-user"))
    refused(probe(fixture, known_hosts, "printf refused", user="root"))
    refused(probe(fixture, known_hosts, "printf refused", user="u200001"))
    refused(
        probe(
            fixture,
            known_hosts,
            "printf refused",
            options=(
                "-o",
                "PubkeyAuthentication=no",
                "-o",
                "PreferredAuthentications=password,keyboard-interactive",
            ),
        )
    )
    wrong_hosts = work / "wrong_known_hosts"
    wrong_hosts.write_text(
        f"@cert-authority {PRINCIPAL} {(fixture / 'wrong-user.pub').read_text().strip()}\n"
    )
    refused(probe(fixture, wrong_hosts, "printf refused"))
    print("native SSH foreign authority refusals verified", flush=True)
    success(
        probe(
            fixture,
            known_hosts,
            'set -eu; mkdir -p "$HOME/.ssh"; chmod 700 "$HOME/.ssh"; '
            "printf 'printf native-prelogin-startup\\n' > \"$HOME/.bashrc\"; "
            "printf 'printf native-prelogin-rc\\n' > \"$HOME/.ssh/rc\"; "
            "printf native-startup-prepared",
        ),
        b"native-startup-prepared",
    )
    print("native SSH synthetic startup fixtures prepared", flush=True)
    previous = authority.counters.get("login_refused", 0)
    authority.config = replace(authority.config, allow_login=False)
    try:
        for command in (None, "printf native-user-command-before-receipt"):
            refused(
                probe(
                    fixture,
                    known_hosts,
                    command,
                    options=(
                        "-o",
                        f"SetEnv=SHLVL=0 BASH_ENV={platform.home}/.bashrc ENV={platform.home}/.bashrc",
                    ),
                )
            )
        if authority.counters.get("login_refused", 0) < previous + 2:
            raise RuntimeError("native session did not reach the denied private login authority")
        print("native SSH login receipt refusals verified", flush=True)
    finally:
        authority.config = replace(authority.config, allow_login=True)
    restored = probe(
        fixture,
        known_hosts,
        'set -eu; rm -f "$HOME/.bashrc" "$HOME/.ssh/rc"; printf native-restored',
    )
    # A base login profile can source .bashrc after the successful receipt.
    if restored.returncode != 0 or restored.stdout not in (
        b"native-restored",
        b"native-prelogin-startupnative-restored",
    ):
        raise RuntimeError("native SSH did not recover after restoring login authority")
    print("native SSH login authority restoration verified", flush=True)
    scan = subprocess.run(
        ["ssh-keyscan", "-c", "-t", "ed25519", "-T", "5", network.address],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        check=True,
        timeout=10,
    )
    if len(scan.stdout) > 16_384 or b"ssh-ed25519-cert-v01@openssh.com" not in scan.stdout:
        raise RuntimeError("native SSH did not expose its certified host key")
    certificate = work / "observed-host-cert.pub"
    certificate.write_bytes(scan.stdout)
    fingerprint = subprocess.run(
        ["ssh-keygen", "-l", "-f", str(certificate)],
        stdin=subprocess.DEVNULL,
        capture_output=True,
        check=True,
        timeout=5,
    )
    # OpenSSH fingerprints a certificate's underlying plain public key. Hashing
    # certificate bytes would mistake renewal of the same key for key rotation.
    matched = re.fullmatch(
        rb"256 (SHA256:[A-Za-z0-9+/]{43}) [^\n]* \(ED25519-CERT\)\n", fingerprint.stdout
    )
    if matched is None or len(fingerprint.stdout) > 512:
        raise RuntimeError("native SSH certificate key fingerprint is invalid")
    return matched[1].decode("ascii")


def wait_executor(process: subprocess.Popen[bytes], authority: control.Authority) -> None:
    deadline = time.monotonic() + 90
    while not authority.execution_completed:
        alive(process)
        if time.monotonic() >= deadline:
            raise RuntimeError("native fixed execution deadline exceeded")
        time.sleep(0.25)
    if any(
        authority.counters.get(event, 0) < 1
        for event in ("register", "claim", "started", "completed")
    ):
        raise RuntimeError("native executor omitted a fenced execution phase")


def checkout(context: BootContext, repository: git_fixture.Repository) -> None:
    """@cc [owner:ghuntley,label:verification;security] native-workspace-actual-checkout
    Checkout evidence MUST deliver the source through the boot-bound receiver,
    wait for the actual native Git operation, and verify its commit, shallow
    metadata and fixture file digests through the managed SSH account. A source
    acceptance or a done marker alone MUST NOT establish checkout evidence.
    """
    services.workspace(context.uds, context.boot.binding, repository.source())
    probe = partial(ssh, context.fixture, context.work / "known_hosts", network=context.network)
    deadline = time.monotonic() + 90
    while True:
        alive(context.process)
        status = probe('test "$(cat /run/overalls-workspace/status)" = done')
        if status.returncode == 0 and not status.stdout:
            break
        if time.monotonic() >= deadline:
            raise RuntimeError("native workspace checkout deadline exceeded")
        time.sleep(0.5)
    root = "/workspace/unpublished-fixture"
    success(
        probe(
            f"set -eu; test -f {root}/.git/shallow; test -w {root}; "
            f"{context.platform.git} -C {root} rev-parse HEAD"
        ),
        repository.commit.encode("ascii") + b"\n",
    )
    for name, expected in repository.manifest.items():
        # Names originate only from the closed local fixture, never a request.
        if name not in git_fixture.FILES:
            raise RuntimeError("invalid native checkout fixture manifest")
        result = probe(f"set -eu; test -w {root}/{name}; cat {root}/{name}")
        if result.returncode != 0 or hashlib.sha256(result.stdout).hexdigest() != expected:
            raise RuntimeError("native workspace checkout bytes differ from the fixture")


def metadata(path: Path, binding: services.Binding, network: Network) -> None:
    path.write_text(
        json.dumps(
            {
                "lilly": {
                    "version": 1,
                    "placement": binding.placement_id,
                    "execution_epoch": binding.execution_epoch,
                    "boot_challenge": binding.boot_challenge,
                    "ipv4": network.address,
                    "prefix_length": 32,
                    "gateway": network.gateway,
                    "mac": network.mac,
                }
            }
        ),
        encoding="utf-8",
    )
    path.chmod(0o600)


def run(
    image: Path,
    vmm: Path,
    fixture: Path,
    tap: str,
    work: Path,
    *,
    network: Network = DEFAULT_NETWORK,
    os_name: services.Os = "freebsd",
    verify_boot: Callable[[BootContext], None] | None = None,
    growth: bool = False,
    crash_first_boot: bool = False,
    enable_api: bool = False,
) -> None:
    """@cc [owner:ghuntley,label:verification;security] native-service-machine-scope
    Checks MUST exercise source-built daemons after MMDS/static-network setup
    in Firecracker on a fresh disposable disk. That disk MUST survive verified
    clean shutdowns, or one observed first-boot SIGKILL when explicitly enabled
    for the separate crash oracle. New MMDS authority MUST change boot IDs and refuse
    previous epochs. Synthetic receipts MUST NOT grant catalog admission or
    establish native isolation or crash recovery.
    The default MUST disable the Firecracker API. Only an explicitly enabled
    test oracle MAY receive the private Unix API socket; no TCP control or
    production control endpoint may be introduced.
    """
    platform = Platform(os_name)
    if growth and crash_first_boot:
        raise ValueError("native growth cannot share the crash-recovery scenario")
    work.mkdir(mode=0o700, parents=True, exist_ok=False)
    # Nix normalizes store modes to read-only public files. Restore private
    # permissions on this disposable fixture copy for OpenSSH's key checks.
    local_fixture = work / "authority"
    local_fixture.mkdir(mode=0o700)
    for name in (
        "ca.pem",
        "tls.pem",
        "tls.key",
        "ssh-ca",
        "ssh-ca.pub",
        "user",
        "user.pub",
        "wrong-user",
        "wrong-user.pub",
    ):
        target = local_fixture / name
        shutil.copyfile(fixture / name, target)
        target.chmod(0o600)
    fixture = local_fixture
    git = shutil.which("git")
    if git is None:
        raise RuntimeError("pinned native Git fixture tool is unavailable")
    repository = git_fixture.Repository.create(work / "git", Path(git).resolve())
    manifest = services.decode_object((image / "manifest.json").read_bytes())
    kernel = services.decode_object(json.dumps(manifest.get("kernel")).encode("utf-8"))
    expected = kernel.get("sha256")
    if not isinstance(expected, str) or re.fullmatch(r"[0-9a-f]{64}", expected) is None:
        raise ValueError("missing exact native kernel identity")
    disk = work / "disk.raw"
    shutil.copyfile(image / "disk.raw", disk)
    growth_check: growth_oracle.Oracle | omnios_growth_oracle.Oracle | None = None
    if growth:
        growth_check = (
            growth_oracle.Oracle(disk, work)
            if os_name == "freebsd"
            else omnios_growth_oracle.Oracle(disk, work, expected_kernel_sha256=expected)
        )
    uds = work / "v.sock"
    api = work / "api.sock" if enable_api else None
    metadata_path = work / "metadata.json"
    firmware = image / "firmware"
    config = {
        "boot-source": {"kernel_image_path": str(firmware.resolve())},
        "drives": [
            {
                "drive_id": "rootfs",
                "path_on_host": str(disk),
                "is_root_device": True,
                "is_read_only": False,
            }
        ],
        "machine-config": {"vcpu_count": 2, "mem_size_mib": 2048},
        "vsock": {"guest_cid": 3, "uds_path": str(uds)},
        "network-interfaces": [
            {"iface_id": "native0", "host_dev_name": tap, "guest_mac": network.mac}
        ],
        "mmds-config": {
            "version": "V2",
            "network_interfaces": ["native0"],
            "ipv4_address": "169.254.169.254",
        },
    }
    if growth_check is not None:
        config["drives"].append(
            {
                "drive_id": "foreign",
                "path_on_host": str(growth_check.foreign),
                "is_root_device": False,
                "is_read_only": False,
            }
        )
    config_path = work / "firecracker.json"
    config_path.write_text(json.dumps(config), encoding="utf-8")
    boots: list[services.Boot] = []
    boot_endings: list[str] = []
    host_keys: list[str] = []
    trust_digest = ""
    stage = "boot"
    process: subprocess.Popen[bytes] | None = None
    try:
        for generation in range(3 if growth else 2):
            growth_observation: growth_oracle.Guest | None = None
            if growth_check is not None:
                growth_check.before_boot(generation)
            binding = services.Binding(
                "dddddddd-dddd-4ddd-8ddd-000000000201", 7 + generation, secrets.token_hex(32)
            )
            metadata(metadata_path, binding, network)
            for path in work.glob("v.sock*"):
                path.unlink()
            prepare_api_socket(api, process)
            with (work / "serial.log").open("ab") as serial:
                process = subprocess.Popen(
                    firecracker_arguments(vmm, metadata_path, config_path, api),
                    stdin=subprocess.DEVNULL,
                    stdout=serial,
                    stderr=subprocess.STDOUT,
                )
                try:
                    stage = "boot"
                    boot = wait_kernel(process, uds, binding, expected, platform)
                    print("native service current-boot kernel verified", flush=True)
                    if boots and boot.boot_id == boots[0].boot_id:
                        raise RuntimeError("native restart retained its boot ID")
                    boots.append(boot)
                    stage = "network"
                    subprocess.run(
                        ["ping", "-c", "1", "-W", "5", network.address],
                        check=True,
                        timeout=10,
                        stdout=subprocess.DEVNULL,
                        stderr=subprocess.DEVNULL,
                    )
                    stage = "readiness-withheld"
                    services.readiness_withheld(uds)
                    context = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
                    context.minimum_version = ssl.TLSVersion.TLSv1_2
                    context.load_cert_chain(fixture / "tls.pem", fixture / "tls.key")
                    authority = control.Authority(
                        control.Config(
                            fixture / "ssh-ca",
                            PRINCIPAL,
                            frozenset({network.address}),
                            control.key((fixture / "user.pub").read_text().strip()),
                            execution_probe=True,
                            receipt=work / f"control-{generation}.json",
                        )
                    )
                    with (
                        control.Server(
                            ("169.254.254.1", 443), context, authority, repository=repository
                        ) as server,
                        git_fixture.DNSServer(("1.1.1.1", 53), frozenset({network.address})) as dns,
                    ):
                        thread = threading.Thread(target=server.serve_forever, daemon=True)
                        dns_thread = threading.Thread(target=dns.serve_forever, daemon=True)
                        thread.start()
                        dns_thread.start()
                        try:
                            stage = "trust"
                            trust_digest = services.trust(
                                uds, boot, [(fixture / "ca.pem").read_text()]
                            )
                            stage = "complete-readiness"
                            wait_readiness(process, uds, boot)
                            print("native service complete readiness verified", flush=True)
                            stage = "flush"
                            services.flush(uds, boot)
                            if generation:
                                services.refused(
                                    uds,
                                    1026,
                                    services.encode(
                                        {
                                            "version": 1,
                                            "operation": "sync",
                                            "nonce": secrets.token_hex(32),
                                            **boots[0].binding.fields(),
                                        }
                                    )
                                    + b"\n",
                                )
                            stage = "workspace-refusals"
                            services.workspace_refusals(uds, binding)
                            stage = "terminal-control"
                            services.terminal(uds, binding)
                            stage = "ssh"
                            host_keys.append(
                                ssh_checks(fixture, work, authority, network, platform)
                            )
                            print("native service SSH authority verified", flush=True)
                            if platform.name == "illumos":
                                stage = "installed-omnios-image-verification"
                                verification = (
                                    "set -eu; build_id=$(/usr/bin/cat /etc/overalls/kernel-build-id); "
                                    "/usr/bin/python3.12 -B -E -s "
                                    "/opt/overalls/libexec/image-candidate/native_image.py "
                                    'verify "$build_id" >/dev/null 2>&1; '
                                    "printf native-installed-image-verified"
                                )
                                success(
                                    ssh(
                                        fixture,
                                        work / "known_hosts",
                                        f"{platform.sudo} -n {platform.bash} -c "
                                        + shlex.quote(verification),
                                        network=network,
                                    ),
                                    b"native-installed-image-verified",
                                )
                                print("native service installed OmniOS image verified", flush=True)
                            boot_context = BootContext(
                                uds, boot, fixture, work, network, platform, process, authority, api
                            )
                            stage = "workspace-checkout"
                            checkout(boot_context, repository)
                            print("native service workspace checkout verified", flush=True)
                            stage = "terminal-session"
                            services.terminal_session(uds, binding)
                            print("native service managed PTY verified", flush=True)
                            stage = "executor"
                            wait_executor(process, authority)
                            print("native service fenced execution verified", flush=True)
                            stage = "retained-home"
                            retained_command = (
                                'test "$(cat "$HOME/native-retained")" = native-home-retained'
                                if generation
                                else 'printf native-home-retained > "$HOME/native-retained"'
                            )
                            success(
                                ssh(
                                    fixture,
                                    work / "known_hosts",
                                    "set -eu; "
                                    + retained_command
                                    + "; printf native-home-retained",
                                    network=network,
                                ),
                                b"native-home-retained",
                            )
                            stage = "kernel-recheck"
                            services.kernel(uds, boot, platform.name, expected)
                            if growth_check is not None:
                                stage = "native-root-growth"
                                growth_observation = growth_check.guest(
                                    partial(
                                        ssh,
                                        fixture,
                                        work / "known_hosts",
                                        network=network,
                                    ),
                                    platform.sudo,
                                )
                            if verify_boot is not None:
                                stage = "external-machine-oracle"
                                verify_boot(boot_context)
                            if crash_first_boot and generation == 0:
                                stage = "abrupt-guest-death"
                                alive(process)
                                process.kill()
                                if process.wait(timeout=10) != -signal.SIGKILL:
                                    raise RuntimeError("native guest abrupt death was not observed")
                                boot_endings.append("sigkill")
                            else:
                                stage = "clean-shutdown"
                                shutdown = ssh(
                                    fixture,
                                    work / "known_hosts",
                                    f"{platform.sudo} -n {platform.shutdown} >/dev/null 2>&1",
                                    network=network,
                                )
                                if shutdown.returncode not in (0, 255) or shutdown.stdout:
                                    raise RuntimeError("native SSH shutdown request failed")
                                if process.wait(timeout=60) != 0:
                                    raise RuntimeError("native guest did not exit cleanly")
                                boot_endings.append("clean")
                            if growth_check is not None:
                                stage = "offline-growth-verification"
                                if growth_observation is None:
                                    raise RuntimeError("native growth observation is missing")
                                growth_check.after_shutdown(growth_observation)
                        finally:
                            server.shutdown()
                            dns.shutdown()
                            thread.join(timeout=5)
                            dns_thread.join(timeout=5)
                            if thread.is_alive() or dns_thread.is_alive():
                                raise RuntimeError("native isolated authority did not stop")
                finally:
                    if process.poll() is None:
                        process.terminate()
                        try:
                            process.wait(timeout=10)
                        except subprocess.TimeoutExpired:
                            process.kill()
                            process.wait(timeout=10)
        if len(set(host_keys)) != len(boots):
            raise RuntimeError("native restart retained its SSH host key")
        if growth_check is not None:
            growth_check.finish([boot.boot_id for boot in boots])
        receipt = {
            "version": 1,
            "os": platform.name,
            "boot_ids": [boot.boot_id for boot in boots],
            "boot_endings": boot_endings,
            "kernel_sha256": expected,
            "trust_bundle_digest": trust_digest,
            "image_sha256": digest(image / "disk.raw"),
            "firmware_sha256": digest(firmware),
            "vmm_sha256": digest(vmm),
            "checks": [
                "mmdsv2-current-boot-kernel",
                "assigned-address-reachable",
                "readiness-withheld-without-ssh-authority",
                "trust-installed-and-stale-refused",
                "flush-current-boot-and-refusals",
                "workspace-stale-foreign-malformed-refused",
                "workspace-native-https-shallow-checkout-and-exact-bytes",
                "terminal-hello-ping-and-refusals",
                "terminal-managed-pty-input-resize-replay-and-token-refusal",
                "kernel-current-boot-rechecked",
                "complete-readiness-after-isolated-authority",
                "ssh-certified-host-and-foreign-ca-refusal",
                "ssh-managed-uid-gid-bash-and-passwordless-sudo",
                "ssh-foreign-key-root-foreign-user-and-password-refusals",
                "ssh-login-receipt-before-startup-and-client-environment",
                "executor-private-https-fixed-command-completed",
                "first-boot-sigkill-and-final-clean-shutdown"
                if crash_first_boot
                else "ssh-triggered-clean-guest-shutdown",
                "new-mmds-epoch-challenge-and-boot-id",
                "previous-boot-protocol-refused",
                "home-bytes-retained-across-abrupt-restart"
                if crash_first_boot
                else "home-bytes-retained-across-clean-reboot",
                "ssh-host-key-rotated-across-abrupt-restart"
                if crash_first_boot
                else "ssh-host-key-rotated-across-clean-reboot",
                "all-boots-complete-service-oracles",
            ],
            "native_admission": False,
            "scope": (
                "native services with synthetic HTTPS/SSH/Git/DNS authority and an observed first-boot SIGKILL; separate crash oracle required for recovery acceptance; no native isolation or admission"
                if crash_first_boot
                else "native services with synthetic HTTPS/SSH/Git/DNS authority and clean reboot; no native isolation or crash recovery acceptance"
            ),
        }
        (work / "service-receipt.json").write_text(
            json.dumps(receipt, sort_keys=True, indent=2) + "\n", encoding="utf-8"
        )
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError):
        print(f"native service verification failed at stage {stage}", flush=True)
        raise RuntimeError("native service verification failed") from None
    finally:
        metadata_path.unlink(missing_ok=True)


class Options(argparse.Namespace):
    """CLI schema populated through argparse's explicit path conversions."""

    image: Path
    vmm: Path
    fixture: Path
    tap: str
    work: Path
    address: str
    gateway: str
    mac: str
    os_name: services.Os
    growth: bool


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--image", type=Path, required=True)
    parser.add_argument("--vmm", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--tap", required=True)
    parser.add_argument("--work", type=Path, required=True)
    parser.add_argument("--address", default=DEFAULT_NETWORK.address)
    parser.add_argument("--gateway", default=DEFAULT_NETWORK.gateway)
    parser.add_argument("--mac", default=DEFAULT_NETWORK.mac)
    parser.add_argument("--os-name", choices=("freebsd", "illumos"), default="freebsd")
    parser.add_argument("--growth", action="store_true")
    arguments = parser.parse_args(namespace=Options())
    run(
        arguments.image,
        arguments.vmm,
        arguments.fixture,
        arguments.tap,
        arguments.work,
        network=Network(arguments.address, arguments.gateway, arguments.mac),
        os_name=arguments.os_name,
        growth=arguments.growth,
    )


if __name__ == "__main__":
    main()
