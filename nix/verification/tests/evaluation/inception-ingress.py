"""Isolated guest ingress receiver checks; no KVM or public routing claim."""

import copy
import importlib.util
import json
import socket
import struct
import sys
import tempfile
import threading
import unittest
from pathlib import Path
from typing import TypedDict
from unittest.mock import patch

source = Path(sys.argv.pop(1))
flush_source = Path(sys.argv.pop(1))
spec = importlib.util.spec_from_file_location("runtime", source / "runtime.py")
if spec is None or spec.loader is None:
    raise RuntimeError("runtime helper unavailable")
runtime = importlib.util.module_from_spec(spec)
sys.modules["runtime"] = runtime
spec.loader.exec_module(runtime)
SetupError = runtime.SetupError
encode = runtime.encode
publish = runtime.publish
settings_spec = importlib.util.spec_from_file_location(
    "public_settings", source / "public_settings.py"
)
if settings_spec is None or settings_spec.loader is None:
    raise RuntimeError("public settings helper unavailable")
public_settings = importlib.util.module_from_spec(settings_spec)
sys.modules["public_settings"] = public_settings
settings_spec.loader.exec_module(public_settings)
observations_spec = importlib.util.spec_from_file_location(
    "observations", source / "observations.py"
)
if observations_spec is None or observations_spec.loader is None:
    raise RuntimeError("observations helper unavailable")
observations = importlib.util.module_from_spec(observations_spec)
sys.modules["observations"] = observations
observations_spec.loader.exec_module(observations)
ingress_spec = importlib.util.spec_from_file_location("ingress", source / "ingress.py")
if ingress_spec is None or ingress_spec.loader is None:
    raise RuntimeError("ingress helper unavailable")
ingress = importlib.util.module_from_spec(ingress_spec)
sys.modules["ingress"] = ingress
ingress_spec.loader.exec_module(ingress)
flush_spec = importlib.util.spec_from_file_location("flush", flush_source)
if flush_spec is None or flush_spec.loader is None:
    raise RuntimeError("flush helper unavailable")
flush = importlib.util.module_from_spec(flush_spec)
flush_spec.loader.exec_module(flush)
roles_spec = importlib.util.spec_from_file_location("roles", source / "roles.py")
if roles_spec is None or roles_spec.loader is None:
    raise RuntimeError("roles helper unavailable")
roles = importlib.util.module_from_spec(roles_spec)
sys.modules["roles"] = roles
roles_spec.loader.exec_module(roles)


class Boot(TypedDict):
    placement_id: str
    execution_epoch: int
    boot_challenge: str


class Value(TypedDict):
    version: int
    binding: dict[str, object]
    generation: int
    request_id: str
    origins: dict[str, str]


class IngressTest(unittest.TestCase):
    def test_vsock_port_does_not_conflict_with_guest_flush(self) -> None:
        self.assertEqual(ingress.PORT, 1028)
        self.assertNotEqual(ingress.PORT, flush.PORT)

    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        roots = self.root / "system-roots.pem"
        roots.write_bytes(b"test roots")
        image = self.root / "image.json"
        image.write_text(json.dumps({"system_ca": str(roots)}))
        configured_image = patch.object(ingress, "PUBLIC_CONFIG", image)
        configured_image.start()
        self.addCleanup(configured_image.stop)
        self.boot: Boot = {
            "placement_id": "11111111-1111-4111-8111-111111111111",
            "execution_epoch": 1,
            "boot_challenge": "a" * 64,
        }
        self.namespace = "dev-" + "1" * 32 + ".inception.apps.example"
        self.value: Value = {
            "version": 1,
            "binding": {**self.boot},
            "generation": 1,
            "request_id": self.boot["placement_id"],
            "origins": {
                "namespace": self.namespace,
                "control": "control." + self.namespace,
                "apps": "apps." + self.namespace,
            },
        }

    def test_current_boot_and_closed_origins(self) -> None:
        self.assertEqual(ingress.request(encode(self.value), self.boot), self.value)
        mutations = [
            ("version", 2),
            ("generation", True),
            ("generation", 0),
            ("token", "forbidden"),
            ("request_id", "bad"),
        ]
        for key, value in mutations:
            with self.subTest(key=key, value=value):
                bad = dict(self.value, **{key: value})
                with self.assertRaises(SetupError):
                    ingress.request(encode(bad), self.boot)
        for field, value in [
            ("execution_epoch", 2),
            ("execution_epoch", True),
            ("boot_challenge", "b" * 64),
        ]:
            bad = copy.deepcopy(self.value)
            bad["binding"][field] = value
            with self.assertRaises(SetupError):
                ingress.request(encode(bad), self.boot)
        bad = copy.deepcopy(self.value)
        bad["origins"]["control"] += ".evil"
        with self.assertRaises(SetupError):
            ingress.request(encode(bad), self.boot)
        duplicate = encode(self.value)[:-1] + b',"version":1}'
        with self.assertRaises(SetupError):
            ingress.request(duplicate, self.boot)

    def test_parent_discovery_is_namespace_bound_and_immutable_within_boot(self) -> None:
        parent = {
            "label": "dev-" + "1" * 32,
            "zone": "apps.example",
            "origin": "https://parent.example",
        }
        value = dict(self.value, parent=parent)
        self.assertEqual(ingress.request(encode(value), self.boot), value)
        ingress.install(value, self.root)
        environment = (self.root / "namespace.env").read_text()
        self.assertNotIn("parent.example", environment)
        for origin in [
            "http://parent.example",
            "https://[::1]",
            "https://[::ffff:127.0.0.1]",
            "https://parent.example/",
            "https://parent.example:443",
            "https://parent.example:0443",
            "https://parent.example/path",
            "https://parent.example?",
            "https://parent.example#",
            "https://user@parent.example",
            "https://%h",
            "https://$(id)",
            "https://UPPER.example",
            "https://parent.example:0",
            "https://parent.example:65536",
            None,
        ]:
            bad = dict(value, parent=dict(parent, origin=origin))
            with self.subTest(origin=origin), self.assertRaises(SetupError):
                ingress.request(encode(bad), self.boot)
        for update in [
            {"zone": "other.example"},
            {"label": "other-" + "1" * 32},
            {"token": "forbidden"},
        ]:
            with self.assertRaises(SetupError):
                ingress.request(encode(dict(value, parent=dict(parent, **update))), self.boot)
        changed = dict(value, parent=dict(parent, origin="https://other.example"))
        self.assertEqual(ingress.request(encode(changed), self.boot), changed)
        with self.assertRaises(SetupError):
            ingress.install(changed, self.root)
        with self.assertRaises(SetupError):
            ingress.install(self.value, self.root)
        self.assertEqual(json.loads((self.root / "ingress.json").read_bytes())["parent"], parent)

    def test_namespace_reserves_dns_challenge_owner(self) -> None:
        value = copy.deepcopy(self.value)
        namespace = "dev-" + "1" * 32 + ".inception." + "a" * 63 + "." + "b" * 57
        value["origins"] = {
            "namespace": namespace,
            "control": "control." + namespace,
            "apps": "apps." + namespace,
        }
        self.assertEqual(ingress.request(encode(value), self.boot), value)
        value["origins"] = {key: item + "b" for key, item in value["origins"].items()}
        with self.assertRaises(SetupError):
            ingress.request(encode(value), self.boot)

    def test_idempotence_namespace_retention_and_generation(self) -> None:
        ingress.install(self.value, self.root)
        path = self.root / "ingress.json"
        original = path.stat().st_ino
        host = self.root / "public-host"
        environment = self.root / "namespace.env"
        self.assertEqual(host.read_text(), self.value["origins"]["control"] + "\n")
        self.assertCountEqual(
            environment.read_text().splitlines(),
            [
                'PHX_HOST="' + self.value["origins"]["control"] + '"',
                'MARSHALL_INGRESS_ZONE="' + self.value["origins"]["apps"] + '"',
            ],
        )
        environment_inode = environment.stat().st_ino
        changed_poll = dict(self.value, request_id="22222222-2222-4222-8222-222222222222")
        ingress.install(changed_poll, self.root)
        self.assertEqual(original, path.stat().st_ino)
        self.assertEqual(environment_inode, environment.stat().st_ino)
        host.unlink()
        ingress.install(changed_poll, self.root)
        self.assertEqual(host.read_text(), self.value["origins"]["control"] + "\n")
        self.assertNotIn("request_id", json.loads(path.read_bytes()))
        ingress.install(dict(self.value, generation=2), self.root)
        with self.assertRaises(SetupError):
            ingress.install(self.value, self.root)
        changed = copy.deepcopy(self.value)
        changed["origins"]["namespace"] = "another"
        with self.assertRaises(SetupError):
            ingress.install(changed, self.root)

    def test_publication_expiry_binding_and_empty_bootstrap(self) -> None:
        self.assertEqual(ingress.publication(self.value, self.root)["records"], [])
        snapshot = {
            "binding": self.boot,
            "generation": 1,
            "expires_at_ms": 1001,
            "porsche_host_key": None,
            "audi_host_key": None,
            "records": [{"label": "control", "ready": False, "proofs": ["A" * 43]}],
        }
        publish(self.root / "publication.json", encode(snapshot))
        self.assertEqual(
            ingress.publication(self.value, self.root, now=1000)["records"], snapshot["records"]
        )
        self.assertEqual(ingress.publication(self.value, self.root, now=1000)["ttl_ms"], 1)
        self.assertEqual(ingress.publication(self.value, self.root, now=1001)["records"], [])
        self.assertEqual(
            ingress.publication(dict(self.value, generation=2), self.root, now=1000)["records"], []
        )
        publish(self.root / "publication.json", encode(dict(snapshot, expires_at_ms=6001)))
        self.assertEqual(ingress.publication(self.value, self.root, now=1000)["records"], [])

    def test_porsche_uses_independent_local_authority_and_boot_namespace(self) -> None:
        boot = dict(self.boot, address="10.40.0.2", gateway="10.40.0.1")
        config = {key: self.value[key] for key in ["version", "binding", "generation", "origins"]}
        role = roles.porsche(boot, config)
        self.assertEqual(role["bind"], "10.40.0.2")
        self.assertEqual(role["public_origin"], "https://control." + self.namespace)
        self.assertEqual(role["control_plane"], "https://localhost:5443")
        self.assertEqual(role["credential_file"], "/run/porsche/gateway.token")
        self.assertEqual(role["port"], 22)
        self.assertNotIn("token", role)
        for address in ["::1", "10.10.0.2", "10.40.0.1", "10.40.255.255", "010.40.0.2"]:
            with self.subTest(address=address), self.assertRaises((ValueError, SetupError)):
                roles.porsche(dict(boot, address=address), config)
        with self.assertRaises(SetupError):
            roles.porsche(dict(boot, boot_challenge="b" * 64), config)
        with self.assertRaises(SetupError):
            roles.porsche(boot, dict(config, public_origin="https://other.example"))

    def test_audi_derives_paired_local_address_and_fixed_root_connector(self) -> None:
        boot = dict(self.boot, address="10.40.7.9", gateway="10.40.0.1")
        config = {key: self.value[key] for key in ["version", "binding", "generation", "origins"]}
        host = "22222222-2222-4222-8222-222222222222"
        role = roles.audi(boot, config, host)
        self.assertEqual(role["bind"], "10.41.7.9")
        self.assertEqual(role["host_id"], host)
        self.assertEqual(role["control_plane"], "https://localhost:5443")
        self.assertEqual(role["connector_path"], "/run/lilly-ingress/audi.sock")
        self.assertEqual(role["connector_uid"], 0)
        self.assertEqual(role["credential_file"], "/run/audi/gateway.token")
        self.assertNotEqual(role["bind"], roles.porsche(boot, config)["bind"])
        public_config = dict(
            config,
            public={
                "issuer": "https://ca.example.test/directory",
                "accept_terms": True,
                "nameservers": [
                    {"name": "ns1.example.test", "address": "192.0.2.1", "port": 53},
                    {"name": "ns2.example.test", "address": "192.0.2.2", "port": 53},
                ],
                "mailbox": "hostmaster.example.test",
                "issuer_ca_pem": None,
                "trust_pem": None,
            },
        )
        public_role = roles.audi(boot, public_config, host)
        self.assertEqual(
            public_role["tls"],
            {
                "zone": "apps." + self.namespace,
                "trust_file": "/run/credentials/audi.service/issuer-trust.pem",
                "browser_origin": "https://control." + self.namespace,
                "trusted_proxy_peer": "10.40.0.1",
            },
        )
        for bad in [
            dict(boot, address="10.41.7.9"),
            dict(boot, address="::1"),
            dict(boot, execution_epoch=2),
            dict(boot, address="10.40.0.1"),
        ]:
            with self.assertRaises((ValueError, SetupError)):
                roles.audi(bad, config, host)
        for bad_host in [None, "bad", "AAAAAAAA-AAAA-4AAA-8AAA-AAAAAAAAAAAA"]:
            with self.assertRaises(SetupError):
                roles.audi(boot, config, bad_host)
        with self.assertRaises(SetupError):
            roles.audi(boot, dict(config, connector_path="/tmp/other.sock"), host)

    def test_framed_host_exchange_and_other_cid_refusal(self) -> None:
        parent, child = socket.socketpair()
        self.addCleanup(parent.close)
        self.addCleanup(child.close)
        failures = []

        def serve() -> None:
            try:
                ingress.answer(child, (2, 42), self.boot, self.root)
            except Exception as error:
                failures.append(type(error).__name__)

        thread = threading.Thread(target=serve)
        thread.start()
        body = encode(self.value)
        parent.sendall(struct.pack("!I", len(body)) + body)
        parent.settimeout(2)
        (size,) = struct.unpack("!I", parent.recv(4))
        reply = b""
        while len(reply) < size:
            reply += parent.recv(size - len(reply))
        thread.join(2)
        self.assertFalse(thread.is_alive())
        self.assertEqual(failures, [])
        self.assertEqual(json.loads(reply)["request_id"], self.value["request_id"])
        (self.root / "ingress.json").unlink()
        ingress.answer(child, (3, 42), self.boot, self.root)
        self.assertFalse((self.root / "ingress.json").exists())

    def test_declared_oversize_is_rejected_without_reading_body(self) -> None:
        parent, child = socket.socketpair()
        with parent, child:
            parent.sendall(struct.pack("!I", ingress.REQUEST_LIMIT + 1))
            with self.assertRaises(SetupError):
                ingress.answer(child, (2, 42), self.boot, self.root)


unittest.main()
