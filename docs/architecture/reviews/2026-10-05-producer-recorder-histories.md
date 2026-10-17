# Generated native producer and recorder histories

## Scope and architecture impact

Green native baseline is `31f133d821008cc699781851e173d4028729c824`;
published admission main `34daa6b3` is now merged without fixture source changes.
Current integration includes main `d196cec1`; its retained-launch fixture and
local uncertain-ACK tests do not modify this recorder fixture or production client.
ADR-0136 requires acknowledged admission durability, kernel producer attribution,
once-only terminal settlement and permanent source identity. This change extends
the disposable recorder machine fixture with Hypothesis histories. Production
client, recorder, modules, APIs and accepted rationale are unchanged.

Reviewed the production client's admission, monitored worker death, authorized
finish and gap recovery; the recorder's typed admission/producer state; the native
fixture's private control socket; and repository/Nix test contracts. The test
uses the actual source-built Elixir client and Rust recorder with systemd unit
and Unix peer attribution. Its control protocol adds no product authority.

## Property and oracle

Final self-review traced the fixture's admit/finish worker handlers, production
Client/Marker/RPC contracts and all changed driver callers. No contract mismatch
was found in that scope. The Python contract format and declaration discovery
checks passed; Elixir fixture obligations were reviewed manually and compiled in
the native derivation. Fresh agent review remains unavailable due to the session
thread limit; this is an explicit review limitation.

Each history admits one to four workers and restarts the recorder one or two
times with the producer alive. Independent checkpoint reads require the exact
new admission sequence, pending keys, producer identities, admission times and
deadlines, unchanged terminal totals and permanent identity. Coverage metadata
may advance on restart and is outside that equality projection.

Generated success/death mixtures and fixed mixed/all-death witnesses then settle
through the production client. All workers must add exactly one terminal request
and duration; success/failure totals follow the requested mixture. Duplicate
fixture completion requests refuse and preserve the complete totals, next sequence
and exclusions. Further recorder reopens preserve those terminal fields
and identity. Destructive shared-fixture failures retain the first failing case
without shrinking or repeated execution against changed state.

## Verification and limits

Final native execution passed:98seconds, exit0, archive
`1791201680910-110365-0.jsonl`, log
`/tmp/overalls-producer-recorder-reopen-native.log`. Composed driver lint and type
checks passed (events263 and266). The generated history subtest passed in
10.77seconds; the full machine script passed in74.87seconds, including the
original corruption refusal and whole-VM hard-stop checks. The pending/failed
run descriptions below preserve historical evidence. Final repository/handbook
gates were pending at that stage. Integrated main34daa6b3 all-file hooks passed,
including Ruff and ty; combined evaluated handbook/native build passed32seconds,
exit0, archive `1791202105446-363321-0.jsonl`, log
`/tmp/overalls-producer-recorder-main34-hooks.log`. The unchanged native fixture
result was reused; this is integrated build evidence rather than a new runtime
history. The full Marshall gate subsequently passed as recorded below;
final integrated governance gates and publication remain pending.

### Historical execution notes

Pinned Ruff formatting and lint passed. At the first capture, native NixOS execution, composed-driver
typing, final contracts, handbook and project gates are pending. Running native
capture: `1791201099171-3955370-0.jsonl`; log
`/tmp/overalls-producer-recorder-native.log`. A running capture is not passing
execution evidence.

The first native run exited1 at the first admission after the existing whole-VM
hard-stop case. Control hello succeeded, but extracting `.id` returned null and
hid the closed refusal reason. No production defect is established. The initial
patch is preserved at `/tmp/overalls-producer-recorder-initial-native.patch`,
SHA256 `63e2c15f64d53c16b67d7590518d5d7d6be2119a9567c78b4b11db32ad27ac4a`.
The refined fixture waits for the client's running recovery marker and exposes
closed admission refusal data. It additionally monitors the exact worker and
requires its `:killed` death before replying to the fixture kill command.
Refined native execution remains pending.
Source review identifies fixture contamination: the earlier corrupt-storage
subtest deliberately leaves `quality` equal to `corrupt`, and production
`Marker.write/2` refuses corrupt state. Control hello only confirms the fixture
server is alive. The first property therefore correctly encountered unavailable
measurement after reusing that fixture; no production defect is established.
The second run (`1791201348528-4090729-0.jsonl`) was explicitly interrupted after
this source-backed diagnosis while waiting for a running marker; it did not
time out or pass. The histories now run before intentional corruption. That
existing refusal test retains the corrupt marker assertion and exact one-request,
one-success increments relative to its captured preceding totals. Ordered-source
native verification is running in `/tmp/overalls-producer-recorder-ordered-native.log`.
That ordered run exited1 (`1791201589060-45342-0.jsonl`): repeated intentional
recorder restarts reached systemd's `start-limit-hit`. Generated admissions reached
the recorder-reopen path; this was not an accounting counterexample. Each deliberate
reopen now first requires an active healthy recorder, then uses the operator
`reset-failed` action before restart. Production start limits are unchanged; an
already failed recorder cannot pass that prerequisite. Refined native execution
is running in `/tmp/overalls-producer-recorder-reopen-native.log`.
Duplicate refusal here is at the fixture's retired-worker map, not a direct
foreign/duplicate recorder RPC oracle. Recorder acknowledgment loss, racing
worker completion/death, collector delivery, real application journeys, overload,
storage failure, hardware power loss and hosted Antithesis remain separate gaps.

## Terminal Marshall gate result

The full gate on source baseline34daa6b3 plus this owned batch completed with
exit0, log `/tmp/overalls-producer-recorder-main34-precommit.log` (session62829).
It passed1452checks:238properties and1214tests,2excluded, seed773639,
1901.6seconds. PLT construction took7m12.83s and emitted third-party xmerl
missing-specification warnings; the final forced application Dialyzer analysis
took56.35seconds with0errors,0skips and0unnecessary skips. The private database
is released. Integration with newer main and final governance gates remain pending;
this result does not cover subsequent source changes or the broader open gaps.

## Integrated governance result

Main `d196cec1` was merged with owned changes preserved. Both the catalog and
audit contain87rows, including the published uncertain-ACK candidate. The
recorder native fixture and production client are unchanged by this integration;
the prior full Marshall result is baseline-specific and is not a new run on main.
Integrated ADR, HLDD references/receipts, generated coverage, options and domain/
deployment views passed. All-file hooks, including Ruff and ty, passed, followed
by evaluated HLDD in26seconds, exit0, archive
`1791207440532-2930239-0.jsonl`, log
`/tmp/overalls-producer-recorder-main-d196-hooks.log`.
Final evidence-only report/provenance edits require refreshed reviewed receipts
and commit gates. Native ACK-loss and collector/application gaps remain open.
