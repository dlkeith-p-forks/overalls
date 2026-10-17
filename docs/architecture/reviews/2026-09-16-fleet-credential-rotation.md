# Coordinated Marshall credential rotation

Date: 2026-09-16

## Scope and architecture impact

Additional ADR-0032/0033 acceptance work using the existing
[production keyring](../../../marshall/lib/marshall/vault.ex),
[signing configuration](../../../marshall/lib/marshall/secrets.ex), database and
SecretSpec/SOPS interfaces. No production domain,
module, key format or authorization policy changes. The
[machine suite](../../../nix/verification/tests/machines/credential-rotation/default.nix) boots three actual
Marshall machines and a shared PostgreSQL machine. Each application receives a
host-specific encrypted document through the production preparation module.

## Rollout and evidence boundaries

- The [runtime fixture](../../../nix/verification/tests/machines/credential-rotation/fixture.py)
  generates synthetic credentials and independently verifies operator recovery
  for every document. Private transfers use temporary directories outside the
  retained test output; errors omit secret values and raw exceptions.
- Encryption rotation first distributes `[old, new]` to all nodes, preserving the
  old writer key. It then promotes `[new, old]` one node at a time. Actual
  AshCloak host credentials written before and after promotion must authenticate
  through every live service's verified HTTPS provisioner endpoint, including
  nodes that have staged the new key but have not promoted it.
- The [trusted release probe](../../../nix/verification/tests/machines/credential-rotation/probe.exs)
  creates real Ash credentials and stored login tokens in the shared database,
  guarded by a disposable fixture sentinel. Plug generates signed session
  cookies for those tokens. HTTP requests exercise the actual machine-page
  authentication boundary. This tests cookie/token acceptance, not interactive
  browser sign-in or terminal reconnection; those have separate fleet evidence.
- Signing and database credentials use a coordinated stop/prepare/start sequence.
  All three application consumers stop before cutover. Existing database
  credentials, outer cookies and old tokens enclosed in newly signed cookies
  must be rejected. Fresh credentials and logins must work on all nodes.
- The test compares each live process's selected environment with its prepared
  bundle and checks journals without printing secrets. An isolated release probe
  starts without the old encryption key to verify fail-closed access to retained
  old ciphertext; live services retain both keys.

## Findings and decisions

The current signing configuration accepts one signing secret, so a rolling mixed
signing-key interval would produce inconsistent authentication across replicas.
The supported coordinated cutover has an explicit control-plane interruption and
invalidates existing logins. It does not promise seamless signing rotation.

Promoting a Cloak writer key is distinct from retiring a decryption key. Retain
old keys while existing records or retained backups need them. This test does not
implement a bulk re-encryption job, retire old backup keys or prove recovery after
an actual compromise. Host SSH recipient rotation is covered by the separate
[custody review](2026-09-16-secret-host-rotation.md).

## Validation

The complete immutable machine check passed in **249.75 seconds**, using
`r15aig9bn0xhasbbr6dr031lkyb0p686-vm-test-run-kittens-credential-rotation.drv`.
Initial cross-node authentication passed in 6.17 seconds, key staging in 33.02,
writer-key promotion in 44.48, coordinated credential cutover in 45.62, and
missing-retained-key rejection in 5.66. All four machines used actual source-built
releases and production modules, with no diagnostic service overrides.

The first machine run reached real credential creation but failed the fixture's
writer-tag assertion: AshCloak's default stored ciphertext is base64-encoded,
while the probe inspected it as a raw Cloak envelope. The probe now decodes that
representation before checking its tag; production encryption is unchanged.
The next run passed cross-node authentication and both keyring rollout phases,
then exposed another fixture mismatch: libpq selected the test network's IPv6
address while PostgreSQL's synthetic authentication rule deliberately allowed
only the test-network IPv4 subnet. Forcing IPv4 by resolving the local hostname
still selected loopback in the next run. The password probe now uses the
framework-configured primary address directly, retaining `db` for verified TLS
hostname checks. A positive password probe runs at initial setup as well as after
cutover. Authentication rules are unchanged.
Framework type/lint and structural ADR/contract checks pass. Existing application
precommit results remain applicable because no
application source or shared governance tool changed.

## Remaining deployment work

Supply actual deployment documents, authenticate deployment host recipients and
schedule the coordinated interruption for the real topology. Production database
and SMTP/provider acceptance, independent physical failure domains, the existing
reference-host adapter and performance measurements remain separate requirements.
