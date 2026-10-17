# Public Audi wildcard custody review

## Scope and evidence

This review covers the public application certificate path in Marshall, Audi,
the shared ingress-name protocol, PostgreSQL backup recovery and the fleet
NixOS scenario. It compares the implementation with ADR-0105 and the
superseded public-ingress portions of ADR-0047 and ADR-0085. The private
service wildcard in ADR-0078 has a separate trust boundary.

The implementation evidence is the Marshall certificate/account/installation
Ash resources, ACME coordinator and gateway delivery action; Audi's in-memory
TLS store and fleet worker; the ingress-name protocol; and the corresponding
unit, property and machine tests. This is a review of source and observed test
results, not an inference from installed libraries.

## Findings

1. **High — Inception wildcard path has no native acceptance or child restore
   (open).** `Audi.Inception.Front` forwards opaque TLS. The parent wildcard
   cannot cover nested names, so ADR-0106 selects a separate child apps-zone
   wildcard and flat alternate-port labels. The proof-only publication path
   and child issuer configuration have focused checks, but the nested machine
   test stops before child certificate assertions. The staged fixture now
   restarts child Marshall and Audi and compares the served certificate with
   the pre-restart one, but this assertion has not run natively. Lilly's native
   backup captures guest drives, but decryption of restored child PostgreSQL ciphertext with its matching
   Cloak keyring is untested. Nested certificate and authorization acceptance
   remain open.
2. **Medium — Unknown new-order outcomes require bounded retry policy
   (implemented with a remaining evidence gap).** The coordinator persists an
   attempt marker before `newOrder`; a lost response cannot be retried for the
   same generation. After one hour it fails that generation, allowing the next
   due check to allocate another. This limits duplicate orders, though a lost
   successful response can still result in another order after quarantine.
   Unit coverage exercises the transition. A loopback HTTPS ACME test drops
   the `newOrder` reply after accepting the request and confirms that the
   durable attempt marker blocks a second request for that generation. The
   administrator certificate page shows the pending generation and retry
   eligibility time from a bounded, authorized metadata projection. A fleet
   machine network fault test remains outstanding.
3. **Medium — Shared key expands compromise impact (accepted consequence).**
   Every gateway with the public zone certificate can impersonate any name in
   that zone. Marshall encrypts persistent material with Cloak and delivers it
   only to authenticated gateways; Audi holds it in memory. Rotation after a
   compromised gateway affects the whole zone. This is part of ADR-0105's
   accepted tradeoff. The Audi operations guide directs operators to fence
   the gateway, revoke its credential, rotate the wildcard, and verify
   replacement installation on every serving gateway.
4. **Medium — Recovery requires matched database and keyring (native decrypt
   passed).** The PostgreSQL dump holds Cloak ciphertext; the separately
   protected keyring is needed to decrypt it. Audi has no persistent public
   certificate directory. The backup machine scenario creates real AshCloak
   account and active certificate fields, restores the dump and fixture
   keyring into an isolated database, then starts a fresh Marshall release. It
   rejects an unrelated keyring and decrypts all fields against their saved
   digests with the matching one. The fixture keyring is
   disposable; production recovery still requires its SOPS-protected keyring
   and reconciliation with surviving gateways.
5. **Medium — Retired per-VM issuer source (resolved in source).** The deployed
   Audi supervisor starts the fleet worker. Marshall's private Audi API omits
   the former per-VM issuance and direct proof-read routes; its Ash issuance
   resource now exposes read-only historical rows and PaperTrail versions.
   Complete DNS snapshots ignore historical per-VM issuance proofs. The child
   has its own wildcard issuer in source. Route admission and current
   projection unconditionally require the active wildcard and an exact current
   gateway installation receipt. Audi's per-VM issuer, custody, transport,
   client actions and local certificate store have been retired. The remaining
   proof-broker helper has no production caller and does not issue certificates.
6. **High — Gateway fetch was indefinitely deferred by a negative monotonic
   clock (resolved in native verification).** The worker
   used `0` as its initial next-fetch deadline, but `System.monotonic_time/1`
   returned `-576460751849` milliseconds on this host. Three native runs
   activated a certificate without any
   gateway fetch event or installation. Initializing the deadline from the
   current monotonic clock addresses this; subsequent native runs installed and
   acknowledged generation 1 on both gateways. A later native run passed
   gateway restart and same-generation reload after the CA was stopped.
7. **Low — Audi's privacy filter hid reviewed failure stages (implementation
   defect).** The logger catalog accepted the worker's `reason` atom, but the
   source privacy filter retained only UUID identifiers. A closed allowlist now
   retains certificate stages, control transport outcomes and a bounded ready
   generation while rejecting arbitrary values; the focused privacy suite
   passes. This changes no secret or payload logging boundary.
8. **Medium — Guest fixture progress is now bounded (resolved through browser
   acceptance).** Early fleet runs stopped during guest preparation after
   wildcard installation. Stage markers isolated a guest console HTTP health
   command that did not return. A bounded Python socket probe now completes;
   the native run reached real guest HTTPS, policy revocation and private
   browser approval. Its following SSH fixture stopped while checking the
   guest's inactive `sshd.service`. The fixture now starts the service after
   installing its test key; the next native run passed the independent-key
   OpenSSH path.
9. **Medium — Emergency rotation is audited, with an availability tradeoff.**
   An elevated administrator can request an immediate generation from the
   certificate audit page. The action uses the scheduled renewal lock, rejects
   a second pending generation, and commits the generation, PaperTrail actor
   and administrator event together; its diagnostic event follows commit.
   Activation retires the old generation before every gateway has acknowledged
   the new one, so routes on lagging gateways remain unavailable until they
   install it. The audit page exposes the generation and installation receipts.
10. **High — Browser approval used the private API origin (resolved in native
    verification).** An earlier native fleet run passed real guest HTTPS and
    stream revocation, then failed at the owner's first private browser visit.
    Audi began a login but redirected it to its configured port-5443 machine API,
    while the signed-in browser session and approval route live on the public
    control origin. Audi TLS configuration now requires a separately validated
    browser origin, and a focused redirect test checks the public target. The
    subsequent native run passed the private HTTP and WebSocket browser flow.
11. **High — Physical host declarations still selected removed per-VM options
    (corrected in source, deployment pending).** Overalls and Dungarees
    configured `services.audi.tls.issuer`, `acceptTerms` and `nameservers`, which
    the wildcard-only Nix module no longer accepts. Their declarations now set
    the public browser origin and trust roots; Overalls selects Marshall's
    wildcard issuer and PostgreSQL capture when backups are enabled. Host
    evaluation checks the configuration shape. Backups remain disabled until
    an operator supplies the S3 destination and encrypted backup document;
    no physical wildcard issuance or cutover is claimed.
12. **High — Native Inception acceptance stops at its nested boot prerequisite
    (open).** Pure evaluation of the existing test reaches a `builtins.storePath`
    error in the nested image configuration. With `--impure`, the source-built
    test boots the outer VM and migrates its database, but
    `lilly-inception-preflight.service` fails before producing its bound nested
    Firecracker boot receipt. A test-only 900-second systemd limit ruled out the
    original 300-second service deadline: the probe exited on its own after
    about 312 seconds, still without a receipt. A fixed, payload-free journal
    event added to the probe and observed on the rerun reports
    `nested_proof_timeout`: the outer Firecracker process remained alive but no
    matching nested reply arrived within its 240-second bound. The test-only
    service allowance remains so future failures expose the probe outcome.
    Test-only 8 and 16 GiB cgroup limits also produced the same stage; both
    reached their new limits during the disk copy and neither yielded a receipt.
    Those memory overrides were reverted. This does not identify the failing
    inner boot or reply step.
    No Inception certificate or public forwarding assertion ran, so this test
    neither validates nor contradicts the proposed child wildcard design. The
    inner boot or reply failure still needs diagnosis.
13. **High — Inner Audi retained the removed per-VM ACME configuration
    (corrected in source, native acceptance open).** The inner role builder still supplied issuer,
    per-VM proof, nameserver and certificate-directory fields rejected by the
    wildcard-only Audi parser. It now supplies the child apps zone, public
    control browser origin and trust roots, and the service no longer creates a
    persistent TLS directory. Focused Inception runtime evaluation passes.
    Inner Marshall now receives the child issuer configuration, and the
    child apps-zone apex proof crosses the proof-only parent publication path.
    The native nested boot failure prevents an end-to-end certificate claim.
14. **Medium — Large trust bundles broke repeat child namespace polls
    (resolved in focused runtime verification).** Child ingress publishes
    issuer and chain trust files before releasing its namespace environment.
    The generic private-file reader's 64 KiB default rejected a larger system
    bundle on the next identical poll. The comparison now uses the same 1 MiB
    bound as initial bundle validation. A 100 KiB fixture passes repeated
    installation in the focused Nix runtime check.
15. **High — Complete DNS snapshots retained a route after wildcard rotation
    (corrected in source).** Current-route reads require the active wildcard
    fingerprint and an exact installation receipt from the serving gateway,
    but the complete DNS statement previously checked only the stored route's
    short lease. It could advertise the old route for up to five seconds after
    rotation. The statement now joins the active certificate and exact gateway
    receipt, including the service generation, within its one clock snapshot.
    A focused regression retires the old certificate, activates a replacement
    without a receipt and confirms that both DNS publication and current-route
    reads omit the stale route. The 10,000-route, 100-gateway capacity fixture
    now models receipts; its publication measurement passes. The complete
    public Audi fleet machine test passed against this revision in 887 seconds,
    including issuance, both gateway installations, guest access, revocation,
    CA-offline restart and package recovery.

## Decisions and open questions

ADR-0105 and ADR-0106 are accepted and partial. The main public fleet path is
implemented in source. The child uses its own wildcard, retains opaque parent
TLS forwarding and keeps independent child authentication. Native Inception
acceptance and child PostgreSQL/Cloak recovery remain outstanding.

## Verification

- Protocol `mix precommit`: 201 tests including 74 properties; Dialyzer clean.
- Marshall `mix precommit`: 864 tests/properties, 2 existing exclusions;
  Dialyzer clean after the rotation action, public browser-origin integration
  test update and public wildcard guard on legacy issuance actions.
- Audi `mix precommit`: 178 tests/properties, including 49 properties;
  Dialyzer clean after the failure-stage events, monotonic deadline fix,
  privacy-filter allowlist and public browser-origin edit.
- Audi Nix configuration evaluation passed with separate public browser and
  private machine API origins; repository-wide logging, Ruff and `ty` hooks
  passed after the browser fixture update.
- NixOS module configuration checks passed after verifying that only the
  selected issuer receives ACME directory credentials. Marshall no longer has
  a per-replica legacy issuance enablement flag.
- The Overalls and Dungarees full NixOS system derivations evaluate with the
  wildcard options; Overalls sets PostgreSQL capture true but backup enable
  remains false pending the external destination and credentials. This is
  configuration validation, not a deployed certificate or backup repository.
- Focused administrator audit LiveView tests: 4 passed, including certificate
  history, secret redaction and elevated rotation; these are included in the
  full Marshall gate above.
- Native backup recovery passed with real Marshall AshCloak account and active
  certificate rows. A fresh release rejected an unrelated keyring, then decrypted
  the restored fields using the matching keyring and verified their original
  digests. A native fleet run issued and
  activated the wildcard in three separate runs, but all timed out awaiting
  gateway installation. The fourth and fifth runs, with the monotonic-clock
  fix, installed and acknowledged generation 1 on both gateways. They stopped
  during guest HTTP setup as described above. A later run passed real guest HTTP,
  dual-replica UDP/TCP A answers and live-stream revocation after correcting the
  test's obsolete 20-second TTL expectation. It failed on private browser login
  as described above; the remaining fleet scenario is pending a rerun. A focused
  route, publication and issuance suite passed 53 cases, including 14 properties,
  after updating fixtures to use active wildcard and gateway installation evidence.
  A subsequent native fleet run passed guest HTTP, dual-replica DNS, revocation,
  and private browser HTTP/WebSocket approval before its SSH fixture stopped at
  an inactive guest `sshd.service`. The next run passed independent-key OpenSSH,
  Lilly crash stream closure, SSH revocation, guest isolation, Customer owner
  access, control-plane outage, DNS-node failover and two gateway restarts with
  the CA stopped. It verified the same active wildcard fingerprint and no
  gateway certificate directory after restart. The full native fleet run then
  passed gateway and DNS unhealthy-release and corrective-update recovery
  scenarios in 1097 seconds overall. A second full run after the scheduled
  renewal and emergency rotation allocator were unified passed the same native
  scenarios in 1169 seconds. A third full run with legacy per-VM issuance
  disabled on every public Marshall replica passed in 1323 seconds, including
  its Marshall release rebuild.
- The native Inception test was attempted with `--impure` after pure evaluation
  failed. Its diagnostic rerun observed `nested_proof_timeout` in the outer VM
  journal and stopped before ingress assertions; finding 12 records the
  verification limit. Repository-wide Ruff format, Ruff lint and `ty` hooks
  passed after adding that fixed stage event.
- The focused Inception runtime evaluation passed after removing inner Audi's
  obsolete per-VM ACME fields; this is configuration-shape evidence only.
- The Inception machine driver now stages a child wildcard TLS probe that
  validates two workload names against the same CA-verified certificate and
  rejects the separate control name. The driver evaluates, but the native
  nested boot prerequisite prevents this probe from running.
- ADR structural checker passed for 94 decisions after this review was added;
  it validates structure and local links only.

The final child-proof changes pass Protocol `mix precommit` (204 cases, 74
properties), Audi `mix precommit` (179 cases, 49 properties), Marshall
`mix precommit` (864 cases, 66 properties, 2 existing exclusions) and Lilly
`mix precommit` (388 cases, 43 properties); all four Dialyzer gates are clean.
Repository-wide `prek` passes Ruff format, Ruff lint, `ty` and every logging
catalog check. The ADR checker passes 95 decisions. The focused Inception
runtime and image-builder checks pass, and the impure NixOS Inception driver
derivation evaluates. These checks do not replace the failed native nested
boot/ingress scenario described in finding 12.

After removing the private per-VM issuance and proof-read API routes, the
focused Marshall ingress API, transport and issuance suite passed 49 cases,
including 10 properties; its contracts and forced Dialyzer checks passed.
The complete public Audi fleet NixOS machine test then passed with real
wildcard issuance, installation on both gateways, guest HTTPS and SSH,
policy revocation, gateway restart without the CA, and package recovery.
Repository-wide logging and Python static hooks and the 95-decision ADR
structural check passed against that source tree.

Removing historical per-VM issuance proofs from complete DNS snapshots passed
the Marshall ingress suite: 95 cases, including 21 properties. The regression
case supplies invalid persisted per-VM proof data and confirms that neither
  publication content nor revision allocation depends on it. Marshall contracts,
formatting and forced Dialyzer checks pass for this revision. The complete
public Audi fleet machine test also passed in 946 seconds, including real
wildcard DNS-01 issuance, gateway installation, guest HTTPS and SSH, revocation,
CA-offline restart, and gateway and DNS package recovery.

Marshall's callable per-VM issuance and proof actions have since been removed.
The old issuance resource and PaperTrail table remain readable for audit, and
the regression test inserts a historical proof row directly into the isolated
  test database. The focused ingress/API suite passes 93 cases, including 15
  properties; Marshall contracts, forced Dialyzer, repository static hooks and
  NixOS module evaluation pass.

Audi's old per-VM issuer, account custody, filesystem certificate store and
control protocol have now been removed from active source. The TLS store accepts
one validated wildcard generation in memory and has no legacy SNI fallback.
Focused wildcard TLS tests pass generation, trust, name, key, SNI and restart
checks. Selected Audi tests pass 122 cases, including 29 properties; selected
Protocol tests pass 183, including 69 properties.
Marshall's focused ingress/API suite passes 93 cases, including 15 properties,
and selected Lilly tests pass 378, including 43 properties. Audi,
Protocol and Marshall contracts and forced Dialyzer gates are clean; repository
logging and Python static hooks pass. The complete public fleet NixOS machine
test passed against this removal in 984 seconds. It exercised wildcard DNS-01
issuance, installation on both gateways, guest HTTPS and SSH, revocation,
CA-offline restart with database reload, and gateway and DNS package recovery.
The native backup recovery machine test passed against the same source in 90
seconds. It restored the PostgreSQL custody rows, rejected an unrelated Cloak
keyring, and decrypted the restored account and certificate fields with the
matching keyring.
The loopback HTTPS lost-order-response test passed with the focused Marshall
certificate suite (6 cases); it exercised the real ACME transport and durable
generation state without a fleet network fault.

## Follow-up

Complete native Inception
acceptance and child PostgreSQL/Cloak backup recovery, and add failure
injection for a lost ACME order response. The public fleet path and isolated
parent Cloak restore have native acceptance; the remaining scope keeps
ADR-0105 and ADR-0106 partial.
