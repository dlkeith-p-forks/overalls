# Local Antithesis actor harness

## Scope and architecture impact

The first [Antithesis harness](https://github.com/antithesishq/kittens/blob/9fe1e493b2090d44bacd16089049cd12b316d58a/antithesis/README.md) isolates Lilly's
real durable command Store, VM Actor and journal behind the actor's existing
executor interface. Its fake executor records effective launches in a persistent
volume for the `no-duplicate-generation-launch` property. The harness does not
change a production protocol, Ash resource, persisted production format,
authorization rule, or deployment topology. It adds verification machinery for
the recovery invariant in
[ADR-0017](../decisions/0017-durable-vm-actors-and-host-ownership.md) and the
generation boundary in
[ADR-0016](../decisions/0016-executable-generations-and-lifecycle.md). Both
accepted decisions and their implementation statuses remain unchanged.

## Findings and evidence boundary

The actor receives command intent from the real
[Store](../../../lilly/lib/lilly/control/store.ex), persists attempted generation
in its real [journal](../../../lilly/lib/lilly/vm/journal.ex), and calls the
[fake executor](https://github.com/antithesishq/kittens/blob/9fe1e493b2090d44bacd16089049cd12b316d58a/antithesis/support/fake_executor.exs) through the
existing actor dependency seam. The workload runs separate BEAM processes to
exercise durable same-generation replay and generation advance. A named volume
retains Store, journal, and fake effect records across those process lifetimes.
The [generated Lilly properties](../../../lilly/test/vm/antithesis_actor_property_test.exs)
exercise replay/advance histories across actor lifetimes and a durable fake
launch marker left before the running observation. They assert that the
recovered actor fails that generation without a second fake launch.

This seam can reveal duplicate fake launch effects after actor replay. It cannot
show that a native systemd/Firecracker launch was fenced, or that a guest,
network, ZFS dataset, or independent physical host behaved correctly. Marshall,
PostgreSQL and the authenticated fleet exchange are absent from this first
topology. The broader candidates in the
[property catalog](https://github.com/antithesishq/kittens/blob/9fe1e493b2090d44bacd16089049cd12b316d58a/antithesis/scratchbook/property-catalog.md) are
research input, not implemented assertions; copied evidence predates current
`main` and requires revalidation before use.

## Validation and remaining gaps

The local focused sequence `create`, `replay`, `advance`, `replay` passed in four
separate BEAM processes against one durable directory. The clean Compose image
built from source. `snouty validate antithesis/config --timeout 120` passed,
observed setup completion and discovered the lifecycle driver. Running that
driver inside the built image against a fresh named volume passed; its fallback
JSONL contained six passing unique-attempt `Always` evaluations and two passing
replay `Sometimes` evaluations. The run does not interrupt the actor between
journal attempt and fake effect, and it does not establish that the assertions
can catch an injected bug.

On 2026-09-29, the two StreamData actor properties passed (`2 passed`, 20
generated runs per property). Their injected marker models the post-attempt,
pre-running fault window; it does not kill a process at that exact point or
exercise a native launcher.
Lilly's full `mix precommit` reported `434/435 passed` in its test phase and
Dialyzer found zero errors. Its only failure was the unchanged timing-sensitive
`Lilly.Host.LockTest` property at a 250 ms acquisition budget under the full
suite; the focused file rerun passed (`5 passed`). The new actor properties
passed in the full suite as well as their focused run.

The ADR structural checker, code-contract checker, generated HLDD views,
scenario coverage, generated option reference, and
`nix build .#checks.x86_64-linux.hldd --no-link` passed during this change.
Marshall's `mix precommit` completed compilation and Dialyzer with zero errors,
but exited nonzero because the unchanged generated approval property in
`marshall/test/marshall/agents/agent_revocation_history_test.exs` failed.
Its minimal counterexample was `actions: [:same]` and `withdrawn?: false`:
the test expected `{:error, :unauthorized}` while `CLIAccess.authorize/2`
returned `{:ok, user}`. The focused file rerun reproduced the same failure;
the file and its production implementation have no diff from `origin/main`.
No hosted Antithesis run, triage, cross-timeline query,
debugger session, or mutation sweep has run.
Hosted access and a green baseline are prerequisites for that sweep. A future
full-runtime harness must solve Lilly's host privilege and cgroup requirements
without weakening its authority checks before it can claim exchange or native
execution coverage.
