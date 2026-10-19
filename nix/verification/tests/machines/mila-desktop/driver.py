"""@cc [owner:ghuntley,label:verification] mila-desktop-journey
The Linux Mila bundle MUST be driven with real X input against the packaged
Marshall and Porsche: pending approval, browser approval, the machine list
from a real `ls`, the notifications screen, a forwarded `overalls://` link,
and persistence plus the offline list across a restart. Observations come
only from the integration probe, which reports what the screen shows.
"""

import json
import shlex
import time

HOST = "control.example.test"
MACHINE = "0d9cc041-9db2-4e4c-b28b-1e41d7f472c1"
DATA = "/home/alice/.local/share/dev.overalls.mila"
STATE = "/home/alice/.mila-probe/state.json"
SESSION = (
    "export DISPLAY=:0 XAUTHORITY=/home/alice/.Xauthority "
    "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/1000/bus "
    f"MILA_STATE_FILE={STATE}; "
)


def as_alice(command: str) -> str:
    return "su - alice -c " + shlex.quote(SESSION + command)


def json_object(value: object) -> dict[str, object]:
    if not isinstance(value, dict):
        raise ValueError("Expected JSON object")
    result: dict[str, object] = {}
    for key, item in value.items():
        if not isinstance(key, str):
            raise ValueError("Expected JSON object key")
        result[key] = item
    return result


def probe() -> dict[str, object]:
    status, output = client.execute(f"cat {STATE}")
    if status != 0:
        return {"route": "", "keys": {}, "texts": []}
    try:
        return json_object(json.loads(output))
    except ValueError:
        # The file is replaced atomically; a parse failure is a torn read.
        return {"route": "", "keys": {}, "texts": []}


def route(state: dict[str, object]) -> str:
    value = state.get("route")
    return value if isinstance(value, str) else ""


def keys(state: dict[str, object]) -> dict[str, object]:
    return json_object(state.get("keys", {}))


def texts(state: dict[str, object]) -> list[str]:
    value = state.get("texts")
    if not isinstance(value, list):
        return []
    return [item for item in value if isinstance(item, str)]


def wait_for(description: str, test: "Check", timeout: float = 120) -> dict[str, object]:
    deadline = time.monotonic() + timeout
    state = probe()
    while time.monotonic() < deadline:
        state = probe()
        if test(state):
            return state
        time.sleep(0.5)
    raise AssertionError(
        f"Mila never showed {description}; route={route(state)!r} keys={sorted(keys(state))}"
    )


class Check:
    def __call__(self, state: dict[str, object]) -> bool:
        raise NotImplementedError


class Shows(Check):
    def __init__(self, key: str, at: str | None = None) -> None:
        self.key = key
        self.at = at

    def __call__(self, state: dict[str, object]) -> bool:
        return self.key in keys(state) and (self.at is None or route(state) == self.at)


class Says(Check):
    def __init__(self, text: str) -> None:
        self.text = text

    def __call__(self, state: dict[str, object]) -> bool:
        return self.text in texts(state)


class At(Check):
    def __init__(self, path: str) -> None:
        self.path = path

    def __call__(self, state: dict[str, object]) -> bool:
        return route(state) == self.path


def window() -> str:
    return client.succeed(as_alice("xdotool search --sync --onlyvisible --name '^mila$'")).split()[
        0
    ]


def click(key: str) -> None:
    state = wait_for(f"the {key} widget", Shows(key))
    rect = keys(state)[key]
    if not isinstance(rect, list) or len(rect) != 4:
        raise AssertionError(f"Malformed rectangle for {key}")
    numbers = [item for item in rect if isinstance(item, (int, float))]
    if len(numbers) != 4:
        raise AssertionError(f"Malformed rectangle for {key}")
    x = int(numbers[0] + numbers[2] / 2)
    y = int(numbers[1] + numbers[3] / 2)
    client.succeed(as_alice(f"xdotool mousemove --window {window()} {x} {y} click 1"))


def type_text(value: str) -> None:
    client.succeed(as_alice("xdotool type --delay 40 " + shlex.quote(value)))


def launch() -> None:
    client.succeed(as_alice(f"rm -f {STATE}; install -d -m 700 /home/alice/.mila-probe"))
    client.execute(as_alice("mila >/home/alice/mila.log 2>&1 &") + " &")
    wait_for("its first screen", Shows("open-settings"), timeout=180)


def link(value: str) -> None:
    # The second invocation hands the link to the running instance and exits.
    client.succeed(as_alice("timeout 30 mila " + shlex.quote(value)))


def mode(path: str) -> str:
    return client.succeed(f"stat -c %a {path}").strip()


start_all()
control.wait_for_unit("postgresql-setup.service")
control.succeed("systemctl start overalls-test-migrate.service")
control.wait_until_succeeds(
    "curl --fail --silent --cacert /run/overalls-test/ca.crt https://localhost:4443/health/ready",
    timeout=120,
)
control.succeed("systemctl start mila-desktop-seed.service")
control.succeed("systemctl start porsche.service")
control.wait_for_open_port(22)
control.wait_until_succeeds(
    f"curl --fail --silent --cacert /run/overalls-test/ca.crt --resolve {HOST}:443:127.0.0.1 "
    f"https://{HOST}/bin/ssh-trust.json",
    timeout=60,
)

client.wait_for_x()
client.wait_for_file("/home/alice/.Xauthority")
# The deployment's CA joins the client's system trust: Mila uses only the
# system store, so the bundle it reads is replaced for this boot.
ca = control.succeed("cat /run/overalls-test/ca.crt")
client.succeed("install -d -m 755 /run/mila-ca")
client.succeed("printf '%s' " + shlex.quote(ca) + " > /run/mila-ca/test.crt")
client.succeed(
    "cat /etc/ssl/certs/ca-certificates.crt /run/mila-ca/test.crt > /run/mila-ca/bundle.crt"
)
for bundle in ["/etc/ssl/certs/ca-certificates.crt", "/etc/pki/tls/certs/ca-bundle.crt"]:
    client.succeed(f"mount --bind /run/mila-ca/bundle.crt $(readlink -f {bundle})")
client.succeed(f"curl --fail --silent https://{HOST}/bin/ssh-trust.json")
client.succeed("mkdir -p /root/.pki/nssdb; certutil -N --empty-password -d sql:/root/.pki/nssdb")
client.succeed(
    "certutil -A -d sql:/root/.pki/nssdb -n overalls-fixture -t C,, -i /run/mila-ca/test.crt"
)
token = control.succeed("cat /run/overalls-test/mila-token").strip()
client.succeed("umask 077; printf '%s' " + shlex.quote(token) + " > /root/mila-token")
del token

with subtest("an added deployment waits for browser approval"):
    launch()
    click("deployment-host")
    type_text(HOST)
    click("add-deployment")
    click("sign-in-start")
    state = wait_for("the pending approval", Shows("sign-in-fingerprint"), timeout=120)
    fingerprints = [text for text in texts(state) if text.startswith("SHA256:")]
    assert len(fingerprints) == 1, "Mila shows one key fingerprint"
    fingerprint = fingerprints[0]
    click("sign-in-open")
    client.wait_for_file("/home/alice/approval-url")
    assert mode(f"{DATA}/device-keys") == "700"
    assert mode(f"{DATA}/device-keys/{HOST}.json") == "600"

with subtest("approval in the browser leads to the machine list"):
    client.succeed(
        f"mila-desktop-browser /root/mila-token /home/alice/approval-url {fingerprint}",
        timeout=300,
    )
    listing = f"/d/{HOST}/machines"
    wait_for("the machine list", Shows("machines-search", at=listing), timeout=120)
    # Porsche `ls` ran for real: the empty list is Marshall's answer for this
    # user, not the offline snapshot.
    state = wait_for("the empty list", Says("No machines yet."))
    assert "machines-saved-at" not in keys(state)

with subtest("settings and the offline snapshot are owner-only and hold no secrets"):
    client.wait_for_file(f"{DATA}/snapshots/{HOST}.json")
    for path in ["preferences.json", f"snapshots/{HOST}.json"]:
        assert mode(f"{DATA}/{path}") == "600", path
    assert mode(f"{DATA}/snapshots") == "700"
    preferences = json_object(json.loads(client.succeed(f"cat {DATA}/preferences.json")))
    assert preferences.get("deployments") == [HOST], preferences
    snapshot = client.succeed(f"cat {DATA}/snapshots/{HOST}.json")
    for forbidden in ["approval", "magic_link", "porsche_gateway", fingerprint]:
        assert forbidden not in snapshot, "snapshot holds only machine rows"
        client.fail(f"grep -rF {shlex.quote(forbidden)} {DATA}/preferences.json")

with subtest("notifications are unavailable on Linux and the docs open on the deployment"):
    click("open-notifications")
    wait_for(
        "the notifications explanation",
        Says("Notifications are not available on this platform."),
    )
    click("notifications-docs")
    client.wait_until_succeeds(
        f"grep -qxF https://{HOST}/docs/notifications /home/alice/approval-url", timeout=30
    )

with subtest("a second mila invocation forwards its overalls:// link"):
    link(f"overalls://{HOST}/machines/{MACHINE}")
    wait_for("the linked machine", At(f"/d/{HOST}/machines/{MACHINE}"))
    link("overalls://unknown.example.test/machines")
    wait_for("the deployment list", At("/"))
    windows = client.succeed(as_alice("xdotool search --onlyvisible --name '^mila$'")).split()
    assert len(windows) == 1, "links reuse the running window"

with subtest("after a restart the deployment, lock setting and offline list remain"):
    client.succeed("pkill -u alice -f 'bin/.*mila' || true")
    client.wait_until_fails(as_alice("xdotool search --onlyvisible --name '^mila$'"), timeout=30)
    launch()
    wait_for("the saved deployment", Shows(f"deployment-{HOST}"))
    click("open-settings")
    wait_for("the unavailable lock", Shows("lock-unavailable"))
    assert "lock-on" not in keys(probe())
    # Not signed in yet: the link opens sign-in, which offers the saved list.
    link(f"overalls://{HOST}/machines")
    wait_for("sign-in", At(f"/d/{HOST}/sign-in"))
    click("sign-in-saved-list")
    state = wait_for("the saved list", Shows("machines-saved-at", at=f"/d/{HOST}/machines"))
    assert "machines-offline" in keys(state)

with subtest("Mila never logs the approval link or the login token"):
    mila_log = client.succeed("cat /home/alice/mila.log")
    assert "/ssh/approve/" not in mila_log
    assert "magic_link" not in mila_log
