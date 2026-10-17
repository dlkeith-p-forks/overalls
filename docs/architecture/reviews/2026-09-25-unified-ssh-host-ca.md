# Unified SSH host CA review

## Scope and architecture impact

ADR-0124 supersedes ADR-0118's management-only fingerprint trust. One dedicated
Ed25519 host CA authenticates Porsche, Audi and fresh NixOS/Ubuntu guests, with
twenty-year retirement and ten-year certificates capped at retirement. Marshall
owns signing and the Ash certificate state machine. ADR-0046 user-key proof,
ADR-0110 Cedar accounts and ADR-0115 physical boot authority remain separate.

The source architecture keeps user-key authority separate from host identity.
A fresh CA avoids physical-host-key reuse and guest-readable global secrets.
The native OTP patch is opt-in. Channel-focused unit tests may inject a raw-key
callback for OTP test clients; production runtime configuration exposes no such
setting, and real OpenSSH/machine tests cover the production certificate path.

## Findings and resolution

- **High — shared-key custody:** copying a gateway private key into guests would
  let guest owners impersonate other hosts. The dedicated signer instead has
  recovery and Marshall-only encrypted bundles. Per-boot guest keys stay in
  `/run`; gateways retain distinct keys. Independent Inception deployments
  generate their own persistent authority and never receive the parent's signer.
- **High — routing authority:** trusting a broad CA alone would lose the current
  Audi route-key check. Audi certificates use a SHA256-derived principal, and
  Lyra derives that exact alias from the current verified HTTPS lookup. Its
  isolated OpenSSH process carries user/system revocations and admits no raw
  host-key fallback.
- **High — bootstrap scope:** only the exact private certificate POST may request
  the extended physical boot binding. Marshall locks current service/VM authority
  through signing and commit, derives the principal, and rejects stale or foreign
  boot fields. Certificates never establish user-login authority.
- **Medium — outage history:** a failed signer previously could append another
  generation on each guest sync. The explicit failed-to-pending retry now reuses
  a matching generation, while bounded retention removes at most 500 obsolete
  records per transaction and durably continues a larger batch.
- **Medium — system trust files:** native installer testing found that NixOS's
  system `ssh_known_hosts` symlink was rejected by the private-file reader. A
  separate bounded public-system-trust reader follows configuration links and
  still requires a regular descriptor; managed state and private keys retain
  non-following reads. Regression coverage retains revocations through the link.
- **Medium — fixture validity:** the Audi service fixture now creates real ZFS
  storage and observes its GUIDs before running Lilly. The fleet ACME wait covers
  its minute-scheduled order, proof, finalization and download phases, retaining
  the assertion that the real certificate becomes active.
- **Medium — installer refusal:** integration of main's installer verification
  found that replacing the executable before trust validation lost the refusal
  preservation guarantee. The downloaded executable now configures the stable
  managed path before replacement. Its explicit staged entry skips updater
  delegation to an older installed binary. Real subprocess assertions cover
  successful and refused setup. Generated CA refusal cases and the native
  fixture check a deliberately different prior executable and SSH state.
- **Medium — restart fixture:** the Porsche CA conversion reused its leaf-key
  variable for client trust, invalidating the existing restart comparison. The
  fixture now keeps the trusted CA and persistent leaf separate, asserts they
  differ, and retains the exact leaf-key comparison after gateway failure.
- **Medium — browser fixture:** Audi's native browser probe still expected the
  historical `/machines` login destination. It now asserts the production
  `/overview` destination, matching the other fleet browser probes; private HTTP,
  cookie scope and WebSocket assertions remain intact. Porsche's clone probe now
  opens the machine's `/settings` route rather than its terminal page, preserving
  the refresh-stable request identity and published clone receipt assertions.
- **Medium — image capability mismatch:** the Porsche-only fleet selected the
  minimal image with private services disabled but required host-to-guest trust
  delivery, so provisioning exhausted its three bounded attempts. A shared
  fixture root selection now configures both the image and host requirement.
  The full SSH journeys still enable the receiver, require boot-bound delivery
  and exercise certified guest readiness. Production configuration is unchanged.
- **Medium — image sizing fixture:** the minimal NixOS manifest now requires
  3,244,294,144 bytes, exceeding the generic operator's fixed 3 GiB request.
  Capacity probes therefore failed shape validation before reaching admission.
  The operator now derives its default from the registered immutable image,
  retaining the 3 GiB baseline and bounded explicit overrides. The separate Audi
  heuristic is removed. Only real insufficient-capacity errors satisfy refusal
  assertions; admission accounting and production behavior are unchanged.
- **Medium — restart admission fixture:** the integrated Porsche rerun
  completed both clone paths and clone relocation, then received a generic
  conflict when starting the retained browser clone after deleting the source
  and SSH clone. The response did not preserve the underlying closed admission
  reason, so this run does not establish a lifecycle regression or a passing
  fleet. Restart setup now waits for fresh native host observations and captures
  bounded capacity/lifecycle state on unexpected refusal. Its request identity,
  capacity-only retry and success assertions are unchanged. The next run passed
  the complete lifecycle in 1028.40 seconds, followed by both storage refusals
  and three-Marshall idempotency.
- **Medium — physical capacity fixture:** that run then admitted one additional
  VM where the race expected two. The real pool had only 7.89 GB free, and each
  current image plus portable boot bundle reserves 4,318,035,968 bytes. Admission
  correctly refused the second hold. The legacy logical enrollment budget is
  not an admission limit. Prepared mirrored disks, dataset quota and enrollment
  metadata now share a 16 GiB fixture size. The race reads the preceding real
  reservation and requires fresh native headroom for two but fewer than three
  holds before proceeding. Refusal classification and the final three-VM-per-host
  assertions remain unchanged. The corrected capacity subtest passed in 131.87 seconds.

## Executed validation

The worktree integrated main through `5bce9478`, including `f4939f32`'s bounded
physical boot-proof contention and the installer, Teams, Control room and MFA
verification campaigns.
The following results cover the SSH implementation; full guest journeys and
production acceptance are tracked separately below.

- Full `mix precommit` passed: Protocol 213 (77 properties), Porsche 83
  (11 properties), Audi 143 (31 properties), Lilly 407 (48 properties), Ziggy 37
  (3 properties), and Marshall 1038 (99 properties, 939 tests, plus two host-only exclusions).
  Compiler, contract, logging and forced Dialyzer gates passed. Marshall's last
  run includes failed-generation recovery, bounded retention and Hegel evidence
  recognition tests, plus the integrated Teams, Control room and remembered
  browser/MFA, resize and account-lifecycle histories through `7681806b`. Forced Dialyzer
  completed with zero errors in 65.71 seconds.
- Protocol's certificate properties passed, including signed principal, leaf,
  CA, validity and malformed-input mutations. Marshall's boot-binding test passed
  with independent mutations of all six authority fields.
- Rust all-target tests passed: 71 tests across targets, including certificate
  verification, idempotent trust installation, revocations, bounded reads and
  renewal failure and generated reordered CA denial. Formatting and Clippy with
  warnings denied passed.
- `ssh-host-certificates` passed native OpenSSH against patched OTP across all
  five KEX families with forced rekey. Wrong principal, unsigned fallback,
  unknown/revoked CA, unrelated user key, future and expired certificates fail.
  The final run also passed RSA user authentication with an Ed25519 host
  certificate; its script finished in 13.79 seconds.
- `inception-ssh-host-ca`, `porsche-service`, `porsche-secrets`,
  `porsche-crash-dumps`, `administrative-ssh` and the corrected `audi-service`
  machine tests passed. The Inception probe proves distinct persistent signer
  custody, namespace policy and refusal to silently replace a lost signer;
  it does not prove a complete nested deployment.
- Secret inventory validation passed all 37 documents. `prek run --all-files`
  passed Ruff, Ruff format, ty, structured logging and handbook review. ADR and
  contract syntax/coverage checks passed. The existing fleet runner disables
  composed-driver typing; standalone fragments receive annotation/lint checks.
- Nix `hldd`, `module-configuration` and `hldd-browser` checks passed for the
  integrated domain/topology views. Later prose and source receipt updates are
  checked separately; visual acceptance is not SSH deployment evidence.

## Final contract and authority review

Reviewed the bounded certificate codecs, opt-in OTP negotiation and KEX signing,
production callbacks, typed response validation, service/VM locks and subject
serialization, exact bootstrap routing, atomic file installation, readiness and
renewal, trust installation, digest aliases and encrypted deployment custody.
No remaining contract violation was found in these paths. Atomic certificate and
metadata writes can leave mismatched metadata after interruption; the next run
revalidates and retries instead of treating that state as current. Valid installed
certificates survive renewal outages; invalid/expired identities fail closed.

## Native journey and rollout status

The final integration includes main through `7681806b`, preserving remembered
browser/MFA authority and the Teams, default-profile and handbook verification
changes. The SSH decision is ADR-0124 because main allocated ADR-0123 to remembered
browser authority. The newly integrated Teams SSH and default-OSS native fixtures
now trust the isolated CA and require certified management SSH; their domain
refusal, receipt and guest assertions remain intact. Default-OSS passed in
461.48 seconds, covering browser/Porsche creation, idempotency, Customer refusals
and real guest egress. Teams SSH passed in 46.48 seconds, covering ordinary-user
creation/retry, consenting ownership transfer and stale-user refusals. Porsche's
focused complete lifecycle passed as recorded below; the combined generic suite retains its terminal fixture gap. Both production closures rebuilt successfully after the additional
`7681806b` account-lifecycle integration; the production guest image identities remain unchanged.

The complete NixOS installer journey passed in 1006.32 seconds on the
`253cdcaa`-integrated source. It ran the real curl/Bash installer without seeded
guest pins or authenticity prompts, verified command/PTY access and agent forms,
renewed and reloaded certificates, relocated the guest (289.37 seconds), and
rebooted/cloned it (263.01 seconds). Guest keys differed while client CA trust
stayed unchanged; connecting with the clone's wrong alias was refused.

The complete Ubuntu installer journey passed in 1034.29 seconds on the
`ea8f9870`-integrated source. It passed the same actual installer, command/PTY,
agent and renewal checks, relocation in 255.98 seconds, and reboot/cloning in
257.80 seconds with unchanged CA trust and distinct leaf keys.

The focused CA installer machine test passed in 53.79 seconds. It verified
missing-policy refusal, first installation and actual Porsche account proof,
repeat CA setup, and conflicting/revoked CA refusal preserving a different prior
executable, trust and SSH configuration. Installer input validation passed seven
checks, including one property. The final fixture waits for Marshall readiness,
uses a newline-terminated hosts file for musl, and compares canonical public key
fields independently of the disposable key comment.

Both Overalls and Dungarees production system closures built successfully on the
`6083aeda`-integrated source. These builds include the encrypted signer delivery,
gateway certificate units, both guest images and independent Inception custody.
The full Audi fleet suite passed in 1244.81 seconds with the corrected browser
destination. It exercised real ACME enrollment, private browser HTTP/WebSockets,
certified native per-user SSH and PTY, sharing/key revocation, roster recovery,
Lilly crash recovery, native network isolation, Customer restrictions, authority
expiry, independent DNS, and gateway/DNS failed-update correction.
The Porsche lifecycle passed in 978.55 seconds, including certified management
SSH, gateway restart, sharing, relocation, SSH/browser cloning, clone relocation
and deletion. That run subsequently failed the generic storage-refusal probe
because its fixed disk size was smaller than the image; it is not a passing full
fleet result. The later focused lifecycle and generic-prefix results are recorded below;
production deployment acceptance remains pending. Both full guest journeys
precede the final staged-installer entry correction; its success/refusal and
prior-executable preservation are exercised by the Rust subprocess test and
focused native installer check. Guest certificate issuance and renewal are
unchanged by that entry correction.

Existing guest disks are intentionally not migrated. Long-lived certificates
are not instantly revoked by deleting issuance history; gateway routing still
requires the currently published key, and guest principals include the VM UUID.
CA replacement requires server certificate reissuance as well as explicit client
trust reconciliation; restarting a gateway retains its valid cached certificate.
Full nested
Inception and native macOS execution remain unverified.

The final integration also includes resize verification through `6f58ef65`;
its independent browser driver shares the same real storage fixture configuration.

The subsequent enlarged-storage run passed default-OSS in 438.18 seconds but
again refused the retained browser clone's restart. Its captured state showed
`reported_at = null` on the target immediately after a native reconnect, with
the retained disk and stopped generation intact. The reconnect was at
16:38:46.416 and refusal at 16:38:46.561. A prior freshness check cannot prevent
that intervening authority reset. Porsche now preserves Marshall's existing
closed `host_unavailable` error, and command exit classification reuses the
transport's allowlist. It never retries mutations implicitly. The fixture retries
only explicit pre-admission host/capacity refusal, with the same request ID and
bounded deadline, while rechecking native freshness. Generic conflicts still
fail. HTTPS and runner regression cases include the unavailable-host reason and
refuse extra response fields. The final focused native lifecycle passed as recorded below; the failed
combined run does not establish a whole-fleet pass.

The generic fleet rerun passed the corrected physical-capacity race in 131.87
seconds: exactly two additional admissions, one explicit refusal, three running
VMs per host and six held reservations. Native profile egress and same/cross-host
isolation subsequently passed in 196.03 seconds; subsequent results follow. The working integration now includes account-lifecycle verification
through `7681806b`, preserving its generated histories and native evidence. Its
typed driver uses the same real fixture storage configuration as enrollment.

The generic run also passed real Lilly release upgrades in 330.04 seconds and
an encrypted credential-only update in 236.81 seconds, retaining guest process
identity and repeating native network probes. It then failed personal browser
terminal creation: the UI remained pending with zero sessions. The generic
fixture selects the minimal image with private services disabled; terminald's
on-demand personal account helper requires a verified private roster under
ADR-0117. The same capability mismatch is present on upstream `7681806b`, before
this SSH change. The dedicated terminal fleet enables Audi/private services.
No terminal assertion or production account authority was weakened. Generic
checks after that failure were not executed, and neither this run nor the
combined Porsche/generic check is claimed green. The existing `cloning-fleet`
check selects the same complete Porsche lifecycle, sharing, crash/replay,
cloning, two clone relocations and audit scenarios independently of the generic
terminal fixture; that focused check and resize both passed. This records
an unrelated verification gap rather than whole-fleet acceptance.

## Final pre-deployment verification

On the `7681806b`-integrated source, the complete `cloning-fleet` check passed
in 1022.80 seconds. Its unchanged Porsche lifecycle scenario passed in 868.84
seconds, including certified management SSH, gateway crash/replay, sharing,
source relocation, both clone paths, two clone relocations, independent data
after source deletion, retained browser-clone restart, deletion and clone audit.
The complete `resize-browser` check passed in 300.65 seconds with real running
and stopped guest resizing. Both checks finished successfully in one serialized
Nix build. No terminal scenario or assertion was removed to obtain these results.

Both production closures built on this integration. The `hldd` and
`module-configuration` gates and the composed account-lifecycle driver and
standalone browser type gates passed; this is not a rerun of that account
lifecycle machine journey. Static Python, contract, logging, ADR and handbook
checks passed. Production activation and live two-distribution installer
acceptance are the remaining work for ADR-0124.


## Production startup correction

The initial `0cfa6302` activation installed the expected system closures and
public CA policy on both physical hosts, but gateway certificate acquisition
failed while the fleet HTTPS API was unavailable. The former five-start limit
left Porsche and Audi failed after the API returned. Restarting them after
Marshall and its relay became available obtained valid certificates. A strict
CA-only management connection then listed both published images successfully.
This establishes recovery of issuance, not yet complete deployment acceptance.

The shared gateway startup policy now retries every five seconds without a
terminal start limit, while keeping SSH closed until a valid certificate exists.
Overalls gateways also activate the local fleet API relay socket, which the
updater otherwise restores after consumers. This preserves ADR-0124's signing
boundary and ADR-0036's quiescence; no authority or unsigned fallback is added.
The installer machine test withholds the real Marshall issuer for at least seven
restart attempts, checks the closed listener and absent certificate, then restores
Marshall and requires automatic issuance and native SSH recovery. Audi's custody
test exercises the same retry policy with certificate loss and restoration; that
fixture does not claim live issuance. Both checks passed: installer-trust in
98.24 seconds (real issuer outage/recovery in 49.43 seconds), and Audi service in
79.35 seconds (certificate-loss recovery in 38.63 seconds).

## Live installer acceptance

Both physical updaters marked `0cfa6302` healthy with zero failures after the
initial gateway recovery. The public policy exactly matches the committed
`secrets/ssh-host-ca.pub`, with retirement on 2046-09-25. OpenSSH inspection of
Porsche and both physical Audi gateway certificates confirmed the same dedicated
CA fingerprint and ten-year validity. A strict certificate-only management
connection listed the newly published NixOS and Ubuntu images.

Two owned temporary OSS guests were created through Porsche: `ca-nixos-ad7a72fd`
and `ca-ubuntu-c742d568`. On each, the original three-argument command downloaded
`https://overalls.dev/bin/install.sh` into Bash, installed SSH configuration in
the ordinary user home, and opened a real interactive guest shell without an
authenticity prompt or guest host-key pin. `id -un` returned `geoffrey.huntley`;
`/etc/os-release` identified NixOS 26.11 and Ubuntu 26.04.1 LTS respectively.
The second installation reused the same managed CA trust. This is Linux live
acceptance; native macOS and full nested Inception remain unverified.
Both production system closures and the module/Porsche configuration checks
built with the startup correction. Contract, ADR, handbook, Python format/lint/type
and all-files precommit checks passed. The correction preserves ADR-0124 and
ADR-0036; it changes availability recovery without broadening signing authority.
The follow-up main merge `591ded52` activated the exact locally built closures on
Overalls and Dungarees. Both updaters recorded that revision in `lastHealthy` with
zero failures. Runtime units confirmed the shared disabled start limit and the
Overalls fleet-relay socket dependency; all gateways were active.

Cleanup initially returned `cleanup_failed` and retained both reservations.
Nonforced native destroy attempts reported busy datasets. Read-only inspection
found copies in service namespaces and Nix descriptor-held namespaces. A bounded
operator pass, holding the placement locks and matching the durable deletion
records, found no remaining descriptor-held copies to detach at execution time.
The failed native destroy had left the Ubuntu dataset unmounted; ordinary mount
under its placement lock restored the empty canonical mountpoint for normal
reconciliation. After build completion, Lilly detached 27 namespace copies for
each placement and recorded both datasets destroyed and both VMs deleted at
18:05:03 UTC. Native dataset absence was checked. No forced/lazy unmount, host
reboot, process kill or unrelated guest deletion was used. This records a delayed
cleanup and operator recovery, not new proof that descriptor-only namespace
retention is automatically handled by ADR-0112's process inventory.

Final scope: ADR-0124 is implemented for the authorized fresh-image Linux
journey. The pre-existing generic terminal fixture gap, native macOS and complete
nested Inception limitations above remain explicit.
