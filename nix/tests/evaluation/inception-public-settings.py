"""Shared parent/guest public configuration rejection corpus and local DNS binding."""

import copy
import importlib.util
import json
import sys
import tempfile
import unittest
from collections.abc import Mapping
from pathlib import Path
from typing import NotRequired, TypedDict
from unittest.mock import patch

source = Path(sys.argv.pop(1))
spec = importlib.util.spec_from_file_location("runtime", source / "runtime.py")
if spec is None or spec.loader is None:
    raise RuntimeError("runtime helper unavailable")
runtime = importlib.util.module_from_spec(spec)
sys.modules["runtime"] = runtime
spec.loader.exec_module(runtime)
SetupError = runtime.SetupError
encode = runtime.encode
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
roles_spec = importlib.util.spec_from_file_location("roles", source / "roles.py")
if roles_spec is None or roles_spec.loader is None:
    raise RuntimeError("roles helper unavailable")
roles = importlib.util.module_from_spec(roles_spec)
sys.modules["roles"] = roles
roles_spec.loader.exec_module(roles)

CASES = json.loads(Path(sys.argv.pop(1)).read_text())


class Boot(TypedDict):
    placement_id: str
    execution_epoch: int
    boot_challenge: str


class Configuration(TypedDict):
    version: int
    binding: Mapping[str, object]
    request_id: str
    generation: int
    origins: dict[str, str]
    public: NotRequired[dict[str, object]]


class RoleConfiguration(TypedDict):
    version: int
    binding: Mapping[str, object]
    generation: int
    origins: dict[str, str]
    public: NotRequired[dict[str, object]]


class PublicSettingsTest(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        roots = root / "system-roots.pem"
        roots.write_bytes(b"R" * 100000)
        image = root / "image.json"
        image.write_text(json.dumps({"system_ca": str(roots)}))
        configured_image = patch.object(ingress, "PUBLIC_CONFIG", image)
        configured_image.start()
        self.addCleanup(configured_image.stop)

    def test_shared_protocol_corpus(self) -> None:
        for example in CASES:
            with self.subTest(example=example["name"]):
                if example["valid"]:
                    self.assertEqual(public_settings.validate(example["value"]), example["value"])
                else:
                    with self.assertRaises(SetupError):
                        public_settings.validate(example["value"])

    def test_public_settings_are_immutable_within_the_current_boot(self) -> None:
        boot: Boot = {
            "placement_id": "11111111-1111-4111-8111-111111111111",
            "execution_epoch": 1,
            "boot_challenge": "a" * 64,
        }
        namespace = "dev-" + "2" * 32 + ".inception.apps.example"
        public = next(value["value"] for value in CASES if value["name"] == "public")
        config: Configuration = {
            "version": 1,
            "binding": boot,
            "request_id": boot["placement_id"],
            "generation": 1,
            "origins": {
                "namespace": namespace,
                "control": "control." + namespace,
                "apps": "apps." + namespace,
            },
            "public": public,
        }
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            ingress.install(ingress.request(encode(config), boot), root)
            environment = (root / "namespace.env").read_text()
            self.assertIn("MARSHALL_FLEET_ACME_DIRECTORY=", environment)
            self.assertIn("MARSHALL_FLEET_ACME_NAMESERVERS=", environment)
            self.assertEqual((root / "audi-issuer-ca.pem").read_bytes(), b"R" * 100000)
            self.assertEqual((root / "audi-trust.pem").read_bytes(), b"R" * 100000)
            path = root / "ingress.json"
            original = path.read_bytes()
            inode = path.stat().st_ino
            ingress.install(config, root)
            self.assertEqual(inode, path.stat().st_ino)
            changed = copy.deepcopy(config)
            changed["public"]["issuer"] = "https://other.example/directory"
            changed["generation"] = 2
            with self.assertRaises(SetupError):
                ingress.install(ingress.request(encode(changed), boot), root)
            self.assertEqual(original, path.read_bytes())
            restarted = dict(boot, execution_epoch=2, boot_challenge="b" * 64)
            changed["binding"] = restarted
            ingress.install(ingress.request(encode(changed), restarted), root)
            self.assertEqual(json.loads(path.read_bytes())["public"], changed["public"])

    def test_dns_runtime_uses_own_identity_and_fixed_loopback(self) -> None:
        boot = {
            "placement_id": "11111111-1111-4111-8111-111111111111",
            "execution_epoch": 1,
            "boot_challenge": "a" * 64,
            "address": "10.40.0.142",
        }
        namespace = "dev-" + "2" * 32 + ".inception.apps.example"
        config: RoleConfiguration = {
            "version": 1,
            "binding": {key: boot[key] for key in ingress.BINDING},
            "generation": 1,
            "origins": {
                "namespace": namespace,
                "control": "control." + namespace,
                "apps": "apps." + namespace,
            },
        }
        self.assertIsNone(roles.dns(boot, config))
        public = next(value["value"] for value in CASES if value["name"] == "public")
        config["public"] = public
        result = roles.dns(boot, config)
        self.assertEqual(result["zone"], config["origins"]["apps"])
        self.assertEqual(result["nameservers"], [peer["name"] for peer in public["nameservers"]])
        self.assertEqual((result["bind"], result["port"]), ("127.0.0.1", 53))
        self.assertEqual(result["control_plane"], "https://localhost:5443")
        self.assertNotIn("host_key_dir", result)
        gateway = roles.audi(boot, config, "33333333-3333-4333-8333-333333333333")
        self.assertEqual(gateway["tls"]["zone"], config["origins"]["apps"])
        self.assertEqual(
            gateway["tls"]["browser_origin"], "https://" + config["origins"]["control"]
        )
        self.assertEqual(gateway["tls"]["trusted_proxy_peer"], "10.40.0.1")
        self.assertEqual(
            set(gateway["tls"]),
            {"zone", "trust_file", "browser_origin", "trusted_proxy_peer"},
        )
        invalid = copy.deepcopy(config)
        invalid["public"]["bind"] = "192.0.2.1"
        with self.assertRaises(SetupError):
            roles.dns(boot, invalid)
        with self.assertRaises(SetupError):
            ingress.request(
                encode(dict(config, request_id=boot["placement_id"], token="forbidden")), boot
            )


unittest.main()
