# Audi terminal control-version refusal

## Scope and architecture impact

The all-source property review identified Audi as the remaining HTTP 426
classifier/retry gap in the satellite version-refusal candidate. Reviewed root
and Audi contracts, ADR-0090 DNS placement, ADR-0105 wildcard custody and the
existing Lilly/Ziggy terminal-fence precedent. This change preserves account,
execution, snapshot and certificate authority and adds terminal local recovery
behavior: explicit version refusal halts automatic work until operator restart
after compatibility repair. Transient failures retain their previous retry
policy. No public schema, durable store or fleet placement changes.

## Reproduced failures

Verified local TLS returned 426, but the client returned `http_error` rather than
`unsupported_version`. A generated DNS history independently observed another
control request after 426. The first two-property run failed both properties;
the strengthened retry-only run failed with an actual subsequent request, seed
`751543`, in 6.5 seconds. Logs:
`/tmp/overalls-audi426-initial-reproduction.log` and
`/tmp/overalls-audi426-retry-reproduction.log`.

Fresh read-only review found synchronous readiness cancellation before Fleet's
terminal latch. A suspended scheduler could time out, converting refusal back
to transient polling or restarting its owner. Fleet now unlinks and retires the
temporary scheduler without awaiting a reply; independent job guards observe
scheduler death even when it is suspended. The first test suspended readiness
before the next ordinary polling tick and blocked normal catalog refresh before
reaching the target refusal. The corrected fixture suspends it at the independently
observed terminal request. That initial fixture failure is not passing evidence.

## Repairs and contracts

- Client classifies explicit 426 before response-size and JSON refusal.
- DNS Replica halts refreshes and ignores stale timers while retaining exact
  previously published state and its original expiry.
- SSH KeyPublisher halts publication while retaining local key-file digests.
- FleetWorker preserves the exact version class from fetch/ack/catalog and
  readiness, retires readiness ownership and stops ticks without waiting on
  scheduler cancellation acknowledgements. Installed certificate bytes and
  expiry remain unchanged.
- Readiness accepts terminal results only for a current owned job, cancels other
  jobs, notifies its owner and refuses reopening by ticks or refresh. Slot state
  remains until actual job death. New state interfaces use explicit types.
- The all-file logging gate caught a missing formatter `:owner` allowlist entry;
  the fixed owner atom is now explicitly retained by the reviewed formatter.
- The reviewed Events catalog defines `audi.control_version_refused` before
  emissions. Only fixed owner atoms are recorded; no payload or credentials.

## Recorded local evidence

The repaired first two DNS/transport properties passed in 15.9 seconds, seed
`751543`. The expanded configured TLS property passed in 1.2 seconds: fixed
0/4095/4096/4097/8 MiB/8 MiB+1 families plus generated draws on identity and DNS
routes. DNS's real UDP/TCP answers retain live data and become SERVFAIL at the
original deadline without another control request. Existing focused DNS/readiness/
key suites passed twelve checks (five properties, seven tests) in 21.5 seconds.

The SSH publication file passed one property and one example in 1.3 seconds,
with verified TLS transient prefixes, terminal refusal, queued publication and
exact key digests. Readiness's owned-result cancellation property passed in 1.1
seconds with generated 1/7/16 job counts, actual job death, owner notification
and refused reopening. The three-stage Fleet TLS property passed in 25.3 seconds,
covering fixed fetch/ack/catalog refusal with suspended readiness, a prior
recoverable 503 and unchanged installed certificate metadata.

Logs: `/tmp/overalls-audi426-dns-repaired.log`,
`/tmp/overalls-audi426-configured-tls-focused.log`,
`/tmp/overalls-audi426-owners-existing-focused.log`,
`/tmp/overalls-audi426-key-publisher-focused.log`,
`/tmp/overalls-audi426-readiness-focused.log`,
`/tmp/overalls-audi426-fleet-suspended-focused-repaired.log`.

The expanded five-stage Fleet property passed in 39.9 seconds, seed `751543`.
Fixed fetch/ack/catalog/route-ready/catalog-with-active-job histories plus a
generated stage use actual verified TLS, validated wildcard installation and
listener probes. The active-job stage independently witnesses an Installation
job blocked on route readiness, suspends its scheduler at the next catalog
refusal and observes actual job death. Log:
`/tmp/overalls-audi426-fleet-active-job-focused.log`.

The focused changed-owner and Health suite passed 24 checks (nine properties,
fifteen tests) in 32.7 seconds, seed `751543`; this preceded the latest active-job
stage and added public worker-predicate assertions. Full component verification
is recorded separately below. Health now checks bounded worker predicates:
a successful identity request after compatibility repair cannot make a terminally
halted DNS, SSH publisher or Fleet worker ready before operator restart.

The source-built NixOS audi-dns check passed in 91 seconds, archive
`1791001340991-3357823-0.jsonl`. Its authenticated fixture keeps identity healthy
while DNS snapshots return 426. The actual packaged service becomes unready,
stops snapshot requests, retains its MainPID through restored control and serves
UDP/TCP SERVFAIL after the original five-second deadline. Operator restart
restores answers and readiness. After the build started, the fixture counter
annotation was narrowed from `str` to a closed `Literal` union; runtime behavior
is unchanged, but this execution predates that annotation revision.

The full Audi precommit gate passed 172 checks (48 properties, 124 tests),
seed `484316`, in 149.3 seconds; forced Dialyzer passed in 6.01 seconds with
zero errors and skips. Log: `/tmp/overalls-audi426-full-precommit.log`.
The formatter allowlist correction was made during this gate; subsequent
all-file logging checks verified it, together with Ruff format/check and ty.
The final source-built packaged DNS rerun passed in 105 seconds, archive
`1791001845760-3780571-0.jsonl`, including the final `Literal` annotation and
formatter allowlist. Log: `/tmp/overalls-audi426-final-static-native-repeat.log`.
ADR/HLDD/options/coverage/views checks passed. Evaluated Nix HLDD passed in
21 seconds, archive `1791001729269-3692749-0.jsonl`; final documentation
receipt reconciliation is checked again before commit. Fresh independent
code/test review found no concrete blocker; it performed no extra execution.
Gateway packaged health after SSH/Fleet refusal, real Marshall mixed-version
composition, independent-host availability, certificate-expiry acceptance and
hosted Antithesis coverage remain open. ADRs remain partial; the all-source
property review remains ongoing.

## Integrated gate timeout investigation

The final component repeat at seed `303524` passed 171 of 172 checks (47 of
48 properties and all 124 examples) in 315.5 seconds. The pre-existing invalid
boot property exceeded its 240-second whole-property limit while launching its
126 fresh OTP probes. Its same-seed isolated repeat also hit that module limit
in 253.0 seconds; the CLI default timeout does not override a module tag. No
assertion established that invalid configuration was accepted. Forced Dialyzer
still passed with zero errors/skips in 56.26 seconds. The whole-property budget
is now bounded at 600 seconds, retaining all three complete mutation menus,
all refusal/privacy/immutability assertions and each probe's trace deadlines.
The final component run passed all 172 checks (48 properties, 124 tests),
seed `383978`, in 162.4 seconds; forced Dialyzer passed in 6.33 seconds with
zero errors/skips. Log: `/tmp/overalls-audi426-budget-final-precommit.log`.
The passing run covers the final formatter and test-budget revisions. Earlier logs:
`/tmp/overalls-audi426-final-precommit.log` and
`/tmp/overalls-audi426-invalid-boot-same-seed.log`.
