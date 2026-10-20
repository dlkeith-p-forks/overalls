"""External final-image transport replay; never part of a published payload."""

from __future__ import annotations

import argparse
import hashlib
import json
import secrets
import shlex
import subprocess
import time
from dataclasses import asdict, dataclass
from pathlib import Path
from typing import Literal

import native_reset as reset
import native_service_runner as runner
import native_services as services
import native_transport as transport

Mode = Literal["ordinary", "reset"]
SERVICE = "svc:/site/overalls-native-test-transport:default"
LOGIN_EVENT = (
    b'{"service":"overalls-ssh-authorize","event":"ssh.login_recorded","severity":"info"}\n'
)


@dataclass(frozen=True)
class Fixture:
    """Exact isolated native fixture, with no production-image capability."""

    directory: str
    probe_sha256: str
    mode: Mode


def root_command(context: runner.BootContext, script: str) -> bytes:
    result = runner.ssh(
        context.fixture,
        context.work / "known_hosts",
        f"{context.platform.sudo} -n {context.platform.bash} -c {shlex.quote(script)}",
        network=context.network,
    )
    if result.returncode != 0 or result.stderr != LOGIN_EVENT:
        raise RuntimeError("native test fixture command refused")
    return result.stdout


def upload(context: runner.BootContext, path: str, data: bytes, mode: str) -> None:
    """Stream bounded exact fixture bytes through the already-certified SSH path."""
    if not 0 < len(data) <= 16 * 1024 * 1024 or mode not in ("0400", "0500"):
        raise ValueError("invalid native test fixture upload")
    script = (
        f"set -eu; umask 077; test ! -e {shlex.quote(path)}; "
        f"/usr/bin/cat > {shlex.quote(path)}; /usr/bin/chmod {mode} {shlex.quote(path)}"
    )
    command = f"{context.platform.sudo} -n {context.platform.bash} -c {shlex.quote(script)}"
    result = subprocess.run(
        [
            "ssh",
            "-F",
            "/dev/null",
            "-T",
            "-i",
            str(context.fixture / "user"),
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
            f"UserKnownHostsFile={context.work / 'known_hosts'}",
            "-o",
            f"HostKeyAlias={runner.PRINCIPAL}",
            "-o",
            "HostKeyAlgorithms=ssh-ed25519-cert-v01@openssh.com",
            "-o",
            "LogLevel=ERROR",
            f"{runner.USERNAME}@{context.network.address}",
            command,
        ],
        input=data,
        capture_output=True,
        check=False,
        timeout=45,
    )
    if result.returncode != 0 or result.stdout or result.stderr != LOGIN_EVENT:
        raise RuntimeError("native exact fixture upload refused")


def launch(context: runner.BootContext, probe: Path, *, mode: Mode) -> Fixture:
    """@cc [owner:ghuntley,label:verification;security] external-smf-transport-fixture
    The fixture MUST validate exact uploaded bytes and native SMF syntax before
    starting in its own service contract. Production listeners MUST stop before
    the test process starts so its fixed kernel socket-capacity check is exact.
    Ordinary mode MUST restore production services after a bounded interval.
    Reset mode MUST leave lifecycle disposal to its caller and never claim a
    restored boot, clean shutdown, production service capability or admission.
    """
    if context.platform.name != "illumos" or mode not in ("ordinary", "reset"):
        raise ValueError("external SMF fixture requires an OmniOS boot and closed mode")
    if services.readiness(context.uds, context.boot.binding) != context.boot:
        raise RuntimeError("native transport fixture has no complete-service baseline")
    directory = "/var/tmp/overalls-native-transport-" + secrets.token_hex(16)
    if root_command(context, f"set -eu; umask 077; /usr/bin/mkdir {directory}"):
        raise RuntimeError("native transport fixture directory emitted output")
    probe_bytes = probe.read_bytes()
    expected = hashlib.sha256(probe_bytes).hexdigest()
    upload(context, directory + "/probe", probe_bytes, "0500")
    restore = (
        "/usr/sbin/svcadm enable -t svc:/site/overalls-native-agents:default"
        if mode == "ordinary"
        else ":"
    )
    output = directory + "/probe.log" if mode == "ordinary" else "/dev/console"
    bound = 60 if mode == "ordinary" else 90
    exited = (
        f"printf failed > {directory}/state; exit 1"
        if mode == "ordinary"
        else f'wait "$pid"; pid=; printf verified > {directory}/state; exit 0'
    )
    script = f"""#!/bin/bash
set -eu
export PATH=/usr/sbin:/usr/bin:/sbin:/bin
pid=
finish() {{
  if [ -n "$pid" ]; then kill "$pid" 2>/dev/null || :; wait "$pid" 2>/dev/null || :; fi
  {restore}
}}
trap finish EXIT
trap 'exit 1' HUP INT TERM
/usr/bin/sleep 3
/usr/sbin/svcadm disable -t -s svc:/site/overalls-native-agents:default
{directory}/probe > {output} 2>&1 &
pid=$!
printf active > {directory}/state
attempt=0
while [ "$attempt" -lt {bound} ]; do
  kill -0 "$pid" 2>/dev/null || {{ {exited}; }}
  /usr/bin/sleep 1
  attempt=$((attempt + 1))
done
printf finished > {directory}/state
"""
    manifest = f"""<?xml version="1.0"?>
<!DOCTYPE service_bundle SYSTEM "/usr/share/lib/xml/dtd/service_bundle.dtd.1">
<service_bundle type="manifest" name="overalls-native-test-transport">
  <service name="site/overalls-native-test-transport" type="service" version="1">
    <create_default_instance enabled="false"/>
    <single_instance/>
    <method_context><method_credential user="root" group="root"/></method_context>
    <exec_method type="method" name="start" exec="{directory}/run.sh" timeout_seconds="120"/>
    <exec_method type="method" name="stop" exec=":kill" timeout_seconds="30"/>
    <property_group name="startd" type="framework"><propval name="duration" type="astring" value="transient"/></property_group>
    <stability value="Unstable"/>
    <template><common_name><loctext xml:lang="C">Isolated transport test fixture</loctext></common_name></template>
  </service>
</service_bundle>
"""
    upload(context, directory + "/run.sh", script.encode("ascii"), "0500")
    upload(context, directory + "/service.xml", manifest.encode("ascii"), "0400")
    validation = (
        f'set -eu; test "$(/usr/bin/digest -a sha256 {directory}/probe)" = {expected}; '
        f"/usr/sbin/svccfg validate {directory}/service.xml; "
        f"/usr/sbin/svccfg import {directory}/service.xml; "
        f"/usr/sbin/svcadm enable -t {SERVICE}; printf native-transport-fixture-started"
    )
    if root_command(context, validation) != b"native-transport-fixture-started":
        raise RuntimeError("native fixture did not start after native validation")
    return Fixture(directory, expected, mode)


TRANSPORT_MODULES = {
    "viosock": "/kernel/drv/amd64/viosock",
    "sockvsock": "/kernel/socketmod/amd64/sockvsock",
}
SHADOW_MODULE_PATHS = (
    "/platform/i86pc/kernel/drv/amd64/viosock",
    "/usr/kernel/drv/amd64/viosock",
    "/platform/i86pc/kernel/socketmod/amd64/sockvsock",
    "/usr/kernel/socketmod/amd64/sockvsock",
)


def transport_modules(image: Path) -> dict[str, str]:
    """Return the assembled viosock/sockvsock digests from the exact receipt."""
    assembly = reset.document((image / "evidence/assembly-receipt.json").read_bytes())
    modules = assembly.get("modules")
    if not isinstance(modules, list):
        raise ValueError("assembly receipt has no module records")
    result: dict[str, str] = {}
    for item in modules:
        record = reset.mapping(item)
        name = record.get("name")
        digest = record.get("sha256")
        if not isinstance(name, str) or name not in TRANSPORT_MODULES:
            continue
        if name in result or not isinstance(digest, str) or not services.valid_hex(digest, 64):
            raise ValueError("ambiguous or invalid transport module record")
        result[name] = digest
    if set(result) != set(TRANSPORT_MODULES):
        raise ValueError("assembly receipt lacks transport module digests")
    return result


def loaded_modules(context: runner.BootContext, expected: dict[str, str]) -> dict[str, str]:
    """@cc [owner:ghuntley,label:verification;security] booted-transport-module-identity
    The running kernel MUST list both viosock and sockvsock as loaded modules,
    no shadowing copy may exist on the other native module paths, and the sole
    loadable files MUST equal the assembly receipt digests. This binds loaded
    module names and their files, not a hash of in-memory kernel text.
    """
    listing = (
        "/usr/sbin/modinfo | /usr/bin/awk "
        '\'$6 == "viosock" || $6 == "sockvsock" { print "loaded=" $6 }\' | /usr/bin/sort -u'
    )
    shadows = " ".join(SHADOW_MODULE_PATHS)
    digests = "; ".join(
        f'printf "{name}=%s\\n" "$(/usr/bin/digest -a sha256 {path})"'
        for name, path in TRANSPORT_MODULES.items()
    )
    script = f'set -eu; {listing}; for path in {shadows}; do test ! -e "$path"; done; {digests}'
    lines = root_command(context, script).decode("ascii").splitlines()
    loaded = sorted(line.removeprefix("loaded=") for line in lines if line.startswith("loaded="))
    observed: dict[str, str] = {}
    for line in lines:
        name, separator, value = line.partition("=")
        if separator and name in TRANSPORT_MODULES:
            observed[name] = value
    if loaded != sorted(TRANSPORT_MODULES):
        raise RuntimeError("native transport modules are not both loaded")
    if observed != expected:
        raise RuntimeError("loaded native transport module files differ from assembly")
    return observed


def verify(
    context: runner.BootContext,
    probe: Path,
    build_id: str,
    kernel_sha256: str,
    modules: dict[str, str],
) -> None:
    """Replay exact ordinary transport, then restore the same production boot."""
    fixture = launch(context, probe, mode="ordinary")
    deadline = time.monotonic() + 30
    while True:
        runner.alive(context.process)
        try:
            with transport.connect(context.uds, build_id):
                break
        except (OSError, RuntimeError):
            if time.monotonic() >= deadline:
                raise RuntimeError("isolated native transport did not become ready") from None
            time.sleep(0.25)
    exchanges = transport.exercise(context.uds, build_id)
    print("native transport phase=exchanges-verified", flush=True)
    runner.wait_readiness(context.process, context.uds, context.boot)
    services.kernel(context.uds, context.boot, "illumos", kernel_sha256)
    # Production SSH returns only with the restored listeners; production
    # agents keep both AF_VSOCK modules loaded for the module identity check.
    loaded = loaded_modules(context, modules)
    print("native transport phase=loaded-modules-verified", flush=True)
    completion = root_command(
        context,
        f'set -eu; test "$(/usr/bin/cat {fixture.directory}/state)" = finished; '
        f"/usr/sbin/svccfg delete -f {SERVICE}; printf native-transport-production-restored",
    )
    if completion != b"native-transport-production-restored":
        raise RuntimeError("ordinary transport did not restore the production boot")
    receipt: dict[str, object] = {
        "version": 1,
        "os": "illumos",
        "boot_id": context.boot.boot_id,
        "kernel_sha256": kernel_sha256,
        "transport_build_id": build_id,
        "probe_sha256": fixture.probe_sha256,
        "mode": fixture.mode,
        "guest_cid": 3,
        "peer_cid": 2,
        "malformed_length_refused": True,
        "disconnected_history_recovered": True,
        "production_same_boot_restored": True,
        "loaded_transport_modules": loaded,
        "loaded_module_digests_checked": True,
        "exchanges": [asdict(result) for result in exchanges],
        "native_admission": False,
        "scope": "test-only transport after a complete-service baseline; no reset or DMA acceptance",
    }
    path = context.work / f"transport-{context.boot.boot_id}.json"
    path.write_text(json.dumps(receipt, sort_keys=True, indent=2) + "\n", encoding="utf-8")


class Options(argparse.Namespace):
    image: Path
    vmm: Path
    fixture: Path
    tap: str
    work: Path
    probe: Path
    build_id: str


def validate_image(image: Path, build_id: str) -> str:
    """@cc [owner:ghuntley,label:verification;security] sealed-native-transport-identity
    Transport verification MUST bind its supplied token to the manifest and
    assembly identity, exact kernel, assembly receipt and raw-image digests,
    with both admission fields explicitly false, before starting any VM.
    Ambiguous JSON or missing evidence MUST refuse instead of granting scope.
    """
    manifest = reset.document((image / "manifest.json").read_bytes())
    assembly_path = image / "evidence/assembly-receipt.json"
    assembly = reset.document(assembly_path.read_bytes())
    kernel = reset.mapping(manifest.get("kernel"))
    kernel_sha256 = kernel.get("sha256")
    if (
        not isinstance(kernel_sha256, str)
        or not services.valid_hex(kernel_sha256, 64)
        or not services.valid_hex(build_id, 64)
    ):
        raise ValueError("exact compiled transport token and kernel SHA-256 are required")
    if (
        manifest.get("transport_build_id") != build_id
        or assembly.get("build_id") != build_id
        or reset.mapping(assembly.get("unix")).get("sha256") != kernel_sha256
        or manifest.get("assembly_sha256") != reset.digest(assembly_path)
        or manifest.get("raw_sha256") != reset.digest(image / "disk.raw")
        or manifest.get("native_admission") is not False
        or assembly.get("native_admission") is not False
    ):
        raise ValueError("native transport image identity differs from its exact assembly")
    return kernel_sha256


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("image", "vmm", "fixture", "work", "probe"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--tap", required=True)
    parser.add_argument("--build-id", required=True)
    arguments = parser.parse_args(namespace=Options())
    kernel_sha256 = validate_image(arguments.image, arguments.build_id)
    modules = transport_modules(arguments.image)
    runner.run(
        arguments.image,
        arguments.vmm,
        arguments.fixture,
        arguments.tap,
        arguments.work,
        os_name="illumos",
        verify_boot=lambda context: verify(
            context, arguments.probe, arguments.build_id, kernel_sha256, modules
        ),
    )


if __name__ == "__main__":
    main()
