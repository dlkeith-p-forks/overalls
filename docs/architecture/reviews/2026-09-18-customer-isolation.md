# Customer isolation review — 2026-09-18

## Scope and decisions

ADR-0064 replaces the inherited Customer policies in ADR-0049/0054/0058/0063. Changes span
profile capabilities, fresh owner authorization, web admission, privileged local
connectors and kernel routing. Source work is isolated from other worktrees.

## Findings and resolution

- High: the prior namespace policy intentionally allowed Customer Internet egress.
  [Explicit forwarding denial](../../../lilly/lib/lilly/network/policy.ex) now
  precedes connection-state exceptions; Customer
  is excluded from NAT and web-mark destinations.
- High: public web admission bypasses membership by design. [Profile checks](../../../marshall/lib/marshall/ingress/execution.ex) now
  precede both public access and credential handling on open and renewal.
- High: grants previously authorized Customer collaboration. [Profile-restricted authorization](../../../marshall/lib/marshall/access/authorization.ex)
  now excludes those grants, and sharing mutations are denied.
- High: ADR-0058 formerly granted administrators universal workspace access.
  Customer authorization now requires the owner even for administrators; separate
  fleet inventory, maintenance and revocation are retained under ADR-0064.
- Shared DNS/certificate discovery supports SSH and is retained. It confers no
  service authority. Owner SSH remains an arbitrary-byte channel by design.

## Validation

- Protocol precommit passed: 121 tests/properties, compiler, contracts, ADRs and Dialyzer.
- Lilly precommit passed: 298 tests/properties and forced Dialyzer, with the same gates.
- The native NixOS namespace check passed real marked port-22 transport using echo
  fixtures (not SSH authentication), Customer
  TCP/UDP/DNS/ICMP denial with an unrestricted positive control, web-mark denial
  including port 22, and rejection of already-established outbound and marked-web
  connections after atomic policy replacement. Marked port-22 transport remained
  functional afterward. Owner authorization is covered by Marshall tests.
- Marshall precommit passed 685 tests/properties, including real HTTPS, stale
  SSH/web sessions, owner-only terminal access, administrator denial and UI
  controls, plus distributed tests and forced Dialyzer. Its one existing upstream
  Dialyzer exclusion remains unchanged.
- After integrating origin/main at `00da9b8` (relocation diagnostics), Lilly and
  Marshall precommit passed again with 298 and 685 tests/properties respectively.
- The full `audi-fleet` NixOS check passed in 655 seconds: native owner SSH on a
  Customer Firecracker VM, rejection of Customer sharing and web exposure,
  same/cross-host isolation, authority expiry, gateway/DNS restart and real
  package-update failure/recovery. The VM lifetime checks remained intact.
- The broad `fleet` check stopped before networking in its existing capacity race:
  one admission succeeded where it expected two; reported CPU headroom fell to
  2922 millicores. No capacity assertion was weakened. A dedicated
  `customer-isolation-fleet` check now provisions the six-guest matrix sequentially
  through real admission and retains packet, update, daemon and guest restart probes.
- The dedicated `customer-isolation-fleet` NixOS check passed in 1122 seconds:
  six actual Firecracker guests (Customer, Standard and OSS on each of two Lilly
  hosts), successful non-Customer DNS/HTTP controls, Customer direct-IP/DNS denial,
  same/cross-host and host isolation, spoof/VLAN/IPv6 drops, retained disk data,
  release replacement, credential-only update, forced provisioner termination,
  and Customer stop/start. No capacity-race assertion was removed or relaxed.
- The `relocation-fleet` driver built and passed lint. Its native run passed
  the Customer pre-move direct-IP/DNS egress denial, copied and imported the disk,
  committed the destination and reached running/readiness. Lilly then logged
  `source_cleanup_unconfirmed`; completion remained blocked at source cleanup.
  The attempt was interrupted after that failure and repeated unchanged cleanup
  observations. It is not a passing relocation check: the post-move, return and
  stopped-move network assertions were not reached. Those assertions remain in
  the suite, and relocation acceptance is an explicit gap.
- Final ADR structure/link and code-contract syntax/discovery checks passed.
  Semantic review traced profile checks through authorization, listing, sharing,
  endpoint mutation, web/SSH admission and renewal, local connectors and packet
  filtering; no unresolved contract violation was found in the changed scope.
No production deployment or independent physical-host acceptance is claimed.

## Concurrent main integration

Origin/main advanced to `981ffc8` with private services and Ziggy. Customer's ADR
was renumbered to 0064. Customer input/output drops precede the new private-service
exceptions. Lilly private identity and Marshall inference admission/renewal now
require egress capability. Native private DNS/HTTPS tests retain a Standard
positive control and add Customer timeout assertions. SSH connector validation
preserves the new private-service configuration field; the marked SSH fixture
now enables it. Integrated protocol and Lilly precommit passed with 129 and 300 tests/properties.
The marked SSH/network native check passed in 50 seconds with private services
enabled. The private-services native check passed in 29 seconds: Standard
DNS/TLS remained reachable, while Customer UDP/TCP DNS and HTTPS timed out.
Marshall's integrated run passed 693 tests/properties (62 properties, 631 tests);
the two existing host/capacity exclusions remain. Forced Dialyzer passed with the one unchanged upstream exclusion. The earlier full Firecracker fleet runs preceded this integration;
they are not represented as full fleet reruns of the integrated tree.

The subsequent `9002d5c` deployment/configuration commit was merged without
application-source changes; Customer restrictions and both ADR histories were
preserved. Final ADR/contract checks were repeated after integration.

## Completion audit follow-up

A fresh audit of the pushed tree found that `9002d5c` made Ziggy mandatory on
Lilly hosts while the fleet fixture lacked its secrets input. The fleet now issues
real per-host inference authority through the private-file operator, encrypts it
with fixture-only provider keys through SOPS, supplies a local TLS catalog-only
provider fixture, and requires real Ziggy
readiness after enabling the enrolled hosts. Production service requirements are
unchanged; no disabling override or fabricated readiness is used. On the current
fixture, both hosts passed Ziggy readiness and the first real relocation completed
including source cleanup, retained-data verification and Customer egress denial
on the destination (first-move scenario: 584 seconds). The subsequent return move
timed out at the unchanged 900-second final-transfer deadline. Its destination
retained a receiving journal, no ready disk/VM claim and no launch intent; the
source remained retained and stopped. This is a completed failing broad relocation
run, not a Customer packet-isolation failure. Return/stopped-move acceptance
remains open; no transfer guard or deadline was changed.

| Requirement | Evidence |
| --- | --- |
| Customer guest-initiated traffic denied | Namespace TCP/UDP/DNS/ICMP and private DNS/HTTPS timeout tests, with reachable non-Customer controls; explicit Customer drops before established/private-service rules |
| Only authenticated owner accesses Customer | Marshall owner/stale-grant/admin/session tests; native Customer owner SSH; owner serial-terminal tests |
| Sharing and service exposure impossible through platform APIs | Generated grant/port/visibility tests, real HTTPS rejection, web admission/renewal and privileged web-mark denial including port 22 |
| Profile policy fails closed | Shared capability properties and durable Lilly profile checks |
| Architecture decisions maintained | ADR-0064, reciprocal supersession links and validated index/overview |
| Isolated work and delivery preserve data | Dedicated customer-isolation worktree; normal merges and push through `5daf089`, retaining concurrent main commits |
| Recovery and relocation acceptance | Initial two-host suite passed; integrated packet/update/credential stages passed, but restart setup failed; native first move and destination egress passed; broader return transfer timed out |

The later main integration through `1efb7c0` preserves Customer owner-only checks
with account-retirement fencing and MFA. The administrator-denial regression now
uses a verified MFA session. It also retains the independent fix that keeps the
Customer Audi scenario from overwriting the primary VM's endpoint variable.
Marshall precommit passed on this merged tree: 717 tests/properties (64 properties,
653 tests), two existing host/capacity exclusions, and forced Dialyzer with zero
errors or exclusions. The Customer fleet rerun passed authenticated enrollment/Ziggy readiness (154s),
six-guest placement (163s), initial two-host packet isolation (210s), release
upgrade plus repeated isolation (241s), credential-only rotation plus repeated
isolation (208s), and independent VMM survival across daemon death (21s). Its
last stop/start stage failed at the start request with a fixture `MatchError`
for a non-capacity lifecycle error; post-restart probes were not reached. The
underlying reason was withheld by the fixture, so the slightly stale host report
in diagnostics is not treated as a proven cause. This is a failing complete run,
not a fresh full-suite pass. Earlier stop/start acceptance remains historical.
The merged Audi check passed the real Customer owner-SSH/share/web-denial
scenario in 14.52 seconds, plus packet-mark isolation, live ingress closure on
Lilly crash, SSH-key revocation, control-outage expiry and DNS/gateway restart.
The complete `audi-fleet` run then passed in 870.21 seconds on the consolidated
`5daf089` tree, including gateway and DNS package-update failure/recovery stages
(`/tmp/customer-merged-audi-final.log`, Nix exit 0). After fixture consolidation, the ADR checker passed for 64 decisions; contract
discovery passed for 85 CONTRACTS files and 1,060 native notes across 1,369
maintained source files (structural checks only).

Concurrent main subsequently supplied the equivalent mandatory-Ziggy fixture in
`6a74326`. The final merge uses that single fixture (`ziggy.nix`, local TLS catalog
on m1, issued control tokens and separate SOPS sealing), removes the duplicate
provider TLS derivation and unused operator action, and retains all Customer
assertions. Main through `b57e093` also carries provider selection, IPv4 worker
configuration, private Host forwarding and closed export diagnostics. These do
not grant Customer egress or sharing. The Customer rerun above used the earlier
fixture snapshot; the merged Audi run uses the consolidated fixture.

Final completion audit: Customer firewall, owner authorization, sharing/service
denial, fail-closed capabilities, property/API tests, native packet tests and
ADRs are implemented and committed. Core Customer acceptance is demonstrated
by the executed results above. The broader lifecycle-start and return-transfer
failures remain explicitly recorded rather than weakened or represented as
passing; production deployment was not part of this change. No application
source changed after the passing Marshall gate except upstream closed transfer
diagnostics and private Host forwarding, whose independent validation is recorded
in the Audi review. Original worktree data and concurrent commits were preserved.

Delivery also preserves main `84fb6fc` (reciprocal host Nix builders/caches).
Its host-only forced-command account does not alter guest ingress or profile
policy. After that merge, ADR validation passed for 65 decisions and contract
discovery passed for 85 CONTRACTS files, 1,063 native notes and 1,375 maintained
source files. No Customer application source changed after the native Audi run.
