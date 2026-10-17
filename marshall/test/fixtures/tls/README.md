# Local TLS fixture

The certificate and private key in this directory are intentionally public test
data, used only by ephemeral loopback listeners. Never deploy them or add this
CA certificate to a system trust store. The leaf certificate covers `localhost` and
`127.0.0.1`, issued 2026-09-15 for ten years. Tests pass its path explicitly to
the client as a CA bundle and also verify that a client without that trust rejects it.
The CA signing key was discarded after issuing this fixture.
