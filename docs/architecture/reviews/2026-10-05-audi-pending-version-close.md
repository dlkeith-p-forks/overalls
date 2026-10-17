# Audi pending control-version close

## Scope and architecture impact

Incoming origin98aff42a migrates Audi to ADR-0142's shared control client.
Reviewed Audi's client/link, DNS cadence and directory, HTTP/SSH/TLS callers,
the shared client's lost/pending/status handling and current root/Audi/local
contracts. The change preserves ADR-0142, ADR-0105 custody and existing stored
authority/expiry decisions. It fixes terminal error classification and adds
verification; no new domain, wire format, credential authority or placement.
Self-review only. Full consumer/native acceptance remains separate.

## Findings and repair

**Medium: pending close4001 lost its permanent class.** The shared client
correctly retires pending exchanges as unproven, but Audi classified only an
already-disconnected request through terminal status. Pending reads therefore
became transport_error. The actual verified-TLS close property failed before
any successful draw at prefix0, observing two real peer requests before close;
the first awaited read returned transport_error instead of unsupported_version.
No unauthorized domain effect or extended publication was observed.

Audi now consults current terminal status for unproven as well as disconnected
exchanges. Unsupported_version remains an error, never a completed domain effect;
classification performs no resend. Ordinary loss retains transport_error.
A local contract and explicit response typespec state those obligations.
DNS, SSH publisher and TLS worker/readiness callers already treat the permanent
class as a fence; their other error paths remain failures rather than grants.

**Medium: migrated version fixture weakened the body-size oracle.** Its owner
status426 became a control request error and discarded the synthetic body.
The formerly real HTTPS426/body-size property still passed without exercising
that boundary. It now starts actual verified-TLS servers refusing the upgrade
with configured malformed bodies at0/4095/4096/4097/8388608/8388609bytes.
Both identity and DNS reads must retain the permanent refusal, the shared
client must hold terminal status, and no domain request reaches the peer.
This proves classification without requiring delivery of the entire refused
body after the client closes; it does not establish arbitrary body throughput.

## Recorded evidence

Initial file run: exit2,seed0,24.7seconds; seven of eight checks passed
(three of four properties, all four tests). The new pending-close property
failed on transport_error. Log
`/tmp/kittens-audi-real-version-boundaries-baseline.log`.

After classification repair: exit0,seed0,25.4seconds; eight checks
(four properties,four tests), plus compiler warnings-as-errors and formatting.
Log `/tmp/kittens-audi-real-version-boundaries-repaired.log`.

The added actual-close DNS cadence history then passed with the full file:
exit0,seed0,56.6seconds; nine checks (five properties,four tests).
It uses fixed0/1/2 transient prefixes in each generated draw, halts the public
automatic-work capability before retry, ignores stale timer refs, preserves
exact directory bytes/deadline, and observes healthy UDP followed by TCP
SERVFAIL after the original five-second expiry. Production timers are unchanged.
Log `/tmp/kittens-audi-real-version-cadence-baseline.log`.

The pending-read property now adds actual idle4008 positive controls so an
overbroad permanent classifier is falsifiable. Its refined focused baseline
passed exit0,seed0,33.3seconds: two properties, seven exclusions, log
`/tmp/kittens-audi-real-close-controls-baseline.log`.
Removing only unproven classification in a separate copy failed both properties
in1.6seconds: pending reads lost the permanent class and DNS's public automatic
work fence remained enabled. Source was restored byte-for-byte; the focused
restored baseline passed33.2seconds. The local-audi-pending-version-class ledger
records patch/hash, exact selection and early-assertion scope.
The separate upgrade-class mapping mutant failed the actual HTTP426 property
at the first zero-body DNS case in0.9seconds, one property/eight exclusions.
Restored source matched byte-for-byte and the selected property passed2.2seconds.
The local-audi-upgrade-version-class ledger retains exact patch/hash and scope;
larger-body mutation cases were not reached. Full Audi precommit passed on the
merged source: 182 checks (51 properties, 131 tests), seed 718971, 164.4 seconds.
Forced Dialyzer passed in 5.53 seconds with zero errors, skipped warnings or
unnecessary skips. Compiler, formatting, contracts and ADR gates also passed.
The execution log is `/tmp/kittens-audi-origin-repaired-precommit.log`.
Remaining consumer checks, handbook reconciliation and publication remain open.
Packaged gateway SSH/Fleet pending-close histories, physical mixed-version
deployment and hosted faults remain gaps; prior native DNS evidence retains
its own revision and refusal seam.
