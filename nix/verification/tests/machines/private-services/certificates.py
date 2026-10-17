"""Ephemeral isolated fixture keys; never production inputs."""

import json
import sys
from pathlib import Path

sys.path.insert(0, sys.argv[1])
import authority as pki

root = Path("/run/private-audi")
root.mkdir(mode=0o700)
_, ca, issuer_key, issuer = pki.bootstrap()
key, csr = pki.request()
leaf = pki.issue(csr, issuer_key, issuer)
pki.create_private(root / "key.pem", pki.private_bytes(key))
(root / "roots.pem").write_bytes(pki.public_bytes(ca))
(root / "chain.pem").write_bytes(pki.public_bytes(leaf) + pki.public_bytes(issuer))
(root / "config.json").write_text(
    json.dumps(
        dict(
            version=1,
            role="private",
            host_id="11111111-1111-4111-8111-111111111111",
            connector_path="/run/private-audi/absent.sock",
            connector_uid=0,
            ziggy_socket="/run/private-audi/absent-proxy.sock",
            galileo_socket="/run/private-audi/absent-integration.sock",
            certificate_file=str(root / "chain.pem"),
            key_file=str(root / "key.pem"),
            roots_file=str(root / "roots.pem"),
            status_socket=str(root / "status.sock"),
        )
    )
)
for name in ("roots.pem", "chain.pem", "config.json"):
    (root / name).chmod(0o644)
