# Explicit Galileo attachments and fault validation

## Scope and architecture impact

The user selected explicit personal VM attachments without backwards compatibility
and authorized implementation, production testing and incremental rollout. ADR-0134
accepts that choice, reconciling the earlier deployed shortcut with ADR-0080.
Team automatic availability, management authority, credential custody, execution
fences, schema and protocol remain unchanged. Existing personal integrations have
no source availability until explicitly attached; no backfill is performed.

## Reproduction and verification

The new personal-owner generated history failed before the source repair: actual
unattached admission returned success. The bounded run recorded three of four
properties passing with the new property failing. This is application/Ash/database
evidence with synthetic physical reports, not native transport.

The repaired admission predicate is shared by authorization and renewal. Existing
peer renewal and API positive controls now attach their personal source fixtures.
The focused repaired Marshall run passed four properties and two API tests.
The broader policy/management run passed seven properties and twenty-six tests
(two distributed tests excluded). After adding the supported lifecycle property,
the renewal-history file passed all five properties, including actual account
retirement with a real signed software-passkey assertion and public integration
removal. These are application/database histories with synthetic host reports.
The generated upload cancellation property reproduced a blocked source reader
surviving refusal before repair. The first repaired Galileo suite passed ten
properties and eighteen tests, but the packaged NixOS test then rejected moving
Bandit reads into a worker: its adapter requires the stream owner. That draft
was corrected before deployment. Native body reads now remain in the owner,
while the guardian closes the frontend through ThousandIsland's transport API.
The worker-based source seam remains interruptible for independent callers.
The private listener explicitly disables HTTP/2 because this cancellation seam
is verified against the pinned HTTP/1 adapter, not HTTP/2 stream internals.

A new native blocked-upload refusal workload records actual renewal refusal,
origin dispatch and origin EOF/reset, bounds closure and frontend return to five
seconds, checks no replay, and requires zero active requests. It isolates
Galileo/Bandit from Audi and real Marshall authority. The first packaged native
run passed in 121 seconds, including multi-pull binary upload integrity and
blocked-upload refusal; the latter subtest completed in 3.25 seconds. Expanded
invalid-TTL/expiry histories and independent accepted-TLS counts were added.
The expanded packaged native run passed in 121 seconds. It requires a successful
renewal while the source is silent, then a terminal refusal/invalid response or
blocked renewal, one accepted origin TLS connection independently of one HTTP
dispatch, actual origin EOF/reset, bounded frontend return and no late retry.
These are two local QEMU machines, not physical-host or real-policy acceptance.
Full real-policy withdrawal remains under execution. Galileo's complete precommit gate passed,
including ten properties, eighteen tests and forced Dialyzer with zero errors.
The later Galileo gate passed eleven properties and eighteen tests, adding
generated partial-response prefixes through refusal, invalid TTL, expiry and
consumer halt. The final packaged service run passed in 131 seconds, covering
blocked uploads and partial responses with a successful silent renewal before
each failure, origin EOF/reset, frontend return and zero active requests within
five seconds, independently counted TLS acceptance and no late retries. Each
of the six fault cases uses one original request, not a replayed positive probe.

The final Marshall authority-history file passed five properties in 27 seconds,
including generated stale epochs/placements and refused outsider management with
unchanged audit/state snapshots. The full Marshall test run passed 1,425 cases
(224 properties and 1,201 tests; two distributed tests excluded) in 1,329.7
seconds. The complete Marshall precommit gate passed with forced Dialyzer reporting
zero errors after rebuilding its PLT. The focused stale-fence additions ran
separately after that full suite had loaded the earlier property version; runtime
policy code remained unchanged between them.
The nine-machine withdrawal test first stopped before the withdrawal scenarios:
its post-restart SSH helper fetched the route before verified HTTPS publication.
Positive readiness now shares its existing ninety-second budget between route
publication and actual SSH. Negative authority probes remain single attempts and
still require exact current CA/principal and forbidden evidence. This is a fixture
readiness correction, not a new production permission or transport fallback.
Personal peer setup also now explicitly attaches its source in the fleet fixture.
The corrected nine-machine `integration-renewals` check passed in 575 seconds,
including actual membership/attachment withdrawal after successful renewal,
fresh HTTPS 403 evidence, origin EOF/reset and zero active requests within five
seconds after observed refusal, no extra accepted origin TLS and successful
restoration. The separate `galileo-fleet` check passed in 801 seconds with explicit
personal peer attachment, native multi-chunk bodies, source execution fencing,
all-control-plane outage, cross-host peer provenance and relocation. These real
Firecracker guests run inside local QEMU/KVM machines in one physical failure
domain; they do not establish physical-host production availability.

The final Galileo precommit gate passed thirty cases (eleven properties and
nineteen tests), forced Dialyzer with zero errors, contract discovery/syntax,
structured logging and compiler/format gates. Its final packaged native rerun
passed in 148 seconds after enforcing that an owner-bound source must supply
frontend cancellation before any connection or body read. The all-file Python
format/lint/type and fleet logging gates, ADR structure, generated coverage/options,
Ash/deployment views and Nix handbook gate passed; receipt/source updates are
reviewed again before commit. Structural gates do not extend runtime scope.

Production preparation created two fresh NixOS guests with original persisted
receipts and verified the existing registered-key account. Both reached running
without the earlier campaign's stop/start recovery. Old-policy direct and peer
requests from the owner's unattached source both reached the controlled origin,
reproducing the policy discrepancy before rollout. The first direct probe preceded
origin/route readiness and refused; a verified fresh probe passed after readiness.
The policy/cancellation merge `a43664af` reached main; both hosts subsequently
reported healthy on descendant `b7e29b8f`. Production acceptance then exposed
a separate refusal-classification defect, described below. The account and its existing
authentication factors are unchanged; no temporary account or passkey was created.

## Logging and audit

Attachment changes already retain `galileo_attach`/`galileo_detach` AdminEvent rows,
PaperTrail attribution and post-commit `galileo.integration_configured` events.
Admission refusals use the catalogued closed `galileo.authorization_denied` reason;
upstream outcomes and control failures use Galileo's reviewed catalog. No credential,
token, target origin, payload or per-chunk diagnostic is introduced.

## Production refusal classification

Both serving hosts activated descendant `b7e29b8f`, including the attachment and
cancellation repair. The first two guest observation attempts stopped at HTTPS
known-host discovery404 during route convergence. A subsequent certified SSH
connection recovered without restarting either VM. The observation reader also
needed sudo for its root-owned fixture counters; that operator correction is
not a product fix. A source SSH admission refusal retained its own failed record.

The next real guest request returned503. Marshall recorded
`galileo.authorization_denied` with `unauthorized`, while Galileo recorded
`galileo.control_exchange_failed`. Source review confirmed that the control
client collapsed verified HTTP403 into authority unavailability. Thus admission
was safely refused, but a guest could not distinguish missing attachment from
a control outage. The earlier native withdrawal403 assertion observed the
control exchange, not the guest response; it did not cover this classification.

The repair preserves verified403 as unauthorized regardless of response bytes,
returns guest403 before upload/upstream effects and reuses the reviewed
`galileo.request_denied` catalog event. Renewals retain the same refusal class
and still cancel without retry. Other invalid/outage statuses remain guest503,
and426 remains a distinct version refusal. No authorization, protocol schema,
credential custody or persistence decision changes; ADR-0080/0134 apply.
A generated verified-TLS property checks guest status, unread upload, absent
upstream invocation and unchanged active counters with empty, malformed and
oversized responses. The native fixture now distinguishes synthetic403 refusal
from503 outage on the real Audi/private guest TLS path. Execution and the
follow-up production acceptance remain pending until separately recorded.

The corrected packaged `galileo-service` rerun passed in 132 seconds, archive
`1791003179902-657924-0.jsonl`. It now requires actual guest403 for a stale
execution and explicit authority refusal, guest503 for an explicit synthetic
outage, and unchanged origin dispatch counts. The existing six upload/partial
response cancellation faults also passed. These are two local QEMU machines
with synthetic control, not production policy acceptance. All-file Python Ruff
format/lint and ty, conflict markers and ADR structure passed.

The corrected focused HTTP run passed one property and one test. The initial
property draft omitted the Host request header and then used the Plug test API
that forbids setting that header. Its final fixture follows the existing native
header construction and gives each supervised listener an explicit child ID.
It requires observing the actual control exchange before checking the refusal;
those draft failures do not constitute production defect evidence.

The final Galileo precommit passed 31 cases (12 properties, 19 tests) in 82.8 seconds;
forced Dialyzer reported zero errors, skips or unnecessary skips. Contract,
logging, compiler and format gates passed. Log:
`/tmp/galileo-refusal-precommit-reviewed.log`. Final semantic review traced
Control consumers through admission, renewal and readiness;403 cannot confer
authority or cause an upstream retry. This preserves ADR-0080/0134 boundaries.

## Production acceptance and cleanup

Both hosts reported healthy on `7fda1272`, a descendant of the refusal repair
`570393cc`; the Galileo and attachment-policy sources were unchanged. Certified
source and target SSH readiness passed on their first attempts. A subsequent
new target SSH connection was refused before any integration request. The campaign
retains that failure; its final observation run reused verified OpenSSH connections
with bounded 30-second persistence. A first persistence attempt failed locally
because ProxyCommand requires escaping the ControlPath percent token; the
corrected operator configuration retained CA/principal verification and current
Audi renewal authority. Neither issue is an integration-policy repair, and no
arbitrary fresh-connection reliability claim follows from the successful campaign.

Production direct and peer attachment histories passed. Unattached owner sources
received exact guest403, with unchanged origin counters. Explicit attachment
restored injected-bearer or bound-peer-provenance success; detach again refused
without origin dispatch, and reattachment restored fresh success. Both integration kinds
used the same NixOS source and target on Overalls, not independent host failures.
Direct and peer 1 MiB uploads matched independent SHA-256, exact byte count, POST
method and preserved query, plus the expected credential/provenance comparison.

One original real guest stalled-origin request survived three seconds with an
active lease, exceeding its two-second original TTL. After actual source detach,
a fresh guest403 confirmed withdrawal. The origin recorded one acceptance,
EOF/reset closure and no timeout; Galileo reached zero active requests within
1.81 seconds after that observed refusal. The guest curl terminated with exit22,
and reattachment restored a fresh successful bearer probe. This establishes the
actual guest/Audi/Galileo/Marshall withdrawal path. Invalid-TTL and blocked-control
fault permutations remain native-only; production TLS-dial counting, blocked body
reader/partial response permutations, arbitrary external vendors and physical-host
failure acceptance are not established by this controlled origin campaign.

Private receipts and redacted commands are retained in
`/home/ghuntley/.local/state/kittens/galileo-attachments-20261003`, including
`production-attachments.json`, `production-upload.json`, original terminal VM
creation/deletion receipts and the bounded cleanup authority/physical projections.
Both run-owned integrations were removed through Porsche, and both VM deletions
succeeded under their original request IDs. Independent Ash reads found zero live
fixture VMs/integrations, no compute/disk/startup holds and zero temporary disk
bytes. Independent host reads found no matching ZFS datasets or systemd units.
The guest origin disappeared with its target VM; bounded OpenSSH masters expired
and their empty socket directory was removed. The existing real account remained
live; no temporary account, passkey, host unit or credential was created.

ADR-0134 is now implemented for the selected explicit-personal-attachment policy
and withdrawal contract. ADR-0080 and the broader integration scenario remain
partial for their retained scopes and gaps. The final documentation change adds
production evidence without changing runtime authority or wire schemas.
