# Enrico attempt generation histories

## Scope and architecture impact

Baseline `28f56cf5`. Reviewed ADR-0097, Manager, Git, SLO, HTTP,
application supervision and ancestor/local contracts. This repairs local
single-flight and retained receipt ownership within the accepted decision.
No domain, remote URL, service credential, deployment role or durable authority
changes. Marshall continues to own durable intent and audit.

## Findings and repair

Successful repository removal deleted attempt statuses but left their entries
in the completed queue. After removal and reuse of an attempt identifier, an old
queue entry could evict its new running or terminal status at the 1,024-receipt
boundary. Removal now filters that repository's queue entries and restores the
exact retained count.

Completed tasks also retained monitors until their death notification. A delayed
abnormal death from an older task could match the identifiers of a new task and
settle it as failed. Each admitted task now carries a distinct reference through
its result, monitor and current generation state. Results and abnormal death
require that generation; completion demonitor/flushes its monitor and retires
the generation before reuse.

A final missing-data probe also found that two absent Map values could compare
equal: a completion with nil attempt and nil generation raised `ArgumentError`
instead of preserving empty state. Settlement now requires an actual reference
generation. A fourth property keeps a fixed nil/nil witness plus generated
missing, malformed and unknown generations, requiring exact state retention
and zero outcomes. Final component precommit passed ten checks (seven properties,
three tests), seed `10263`, in 278.9 seconds, exit 0. Forced Dialyzer passed in
4.34 seconds with zero errors, skips or unnecessary skips. Log:
`/tmp/kittens-enrico-missing-generation-final-precommit.log`.

The previous unconditional replay prose contradicted fixed receipt retention.
The contract now states replay for active attempts and retained terminal receipts;
explicit removal, bounded eviction and restart end local retention. This retains
the original durable audit/retry rationale and does not authorize eviction of
active work or substitution of another generation's outcome.

## Verification and limits

Two generated callback properties passed at seed `751543` in 0.3 seconds. These
synthesize admission state and exercise actual handlers, removal and SLO updates.
They check running and terminal replay, exact cap/count conservation, neighbor
eviction order, stale generation result/death and single terminal accounting.

A third property passed with real Manager and Task.Supervisor processes and a
controlled executable at the Git argument-vector boundary. The three-property
file passed at the same seed in 1.0 seconds before adding real cap-crossing
neighbors. Log: `/tmp/kittens-enrico-manager-real-properties.log`.

The expanded real history executes neighbor workers at the 1,023/1,024/1,025
receipt boundaries while the reused task is held, then permits success or kills
its actual owner. The initial sampled run passed three properties at seed
`751543` in 65.3 seconds, exit 0, but did not guarantee every matrix case.
Before the missing-generation property was added, execution passed all three properties at the same seed in 155.8
seconds, exit 0, with fixed witnesses for all six cap/terminal combinations
before three generated histories. Log:
`/tmp/kittens-enrico-manager-fixed-matrix-current.log`. Fresh source review found no
production logic blocker and required guaranteed PATH restoration; this was
fixed before that execution. An earlier default-timeout run failed and provides
no passing evidence. Prior sampled-source component precommit passed nine checks
(six properties, three tests), seed `896984`, in 210.4 seconds; forced Dialyzer
passed in 5.18 seconds with zero errors or skips. The final fixed-matrix component
gate has the passing final result above; integrated checks remain pending. ADR/HLDD references, generated
coverage/options and Ash/deployment views passed. Nix `hldd` passed, exit 0,
archive `1790996693997-4133095-0.jsonl`.

Controlled executable replies do not establish real GitHub/TLS behavior, native
service supervision, physical cache quota or global active-refresh admission.
At this generation-history revision, Tasks supervision and Manager lacked an aggregate active admission cap;
the HTTP connection limit and service memory limit do not prove that contract.
The subsequent [admission review](2026-10-03-enrico-refresh-admission.md) records
a separate bounded policy and overload/refusal/retry histories; generation tests
alone do not establish that bound.
