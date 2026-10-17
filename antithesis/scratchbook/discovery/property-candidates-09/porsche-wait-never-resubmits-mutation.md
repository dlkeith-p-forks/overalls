# porsche-wait-never-resubmits-mutation

P0; high confidence; safety plus conditional progress. SDK callsites **missing** per [fresh scan](../../existing-assertions.md). `Always` **"Porsche wait submits one mutation and only polls its receipt"**: one `Runner.run` invocation sends at most one mutating command; subsequent waits issue only `request show` for the original request ID and accept only matching operation identity. Timeout, transport error or runner death must not submit cancel or another mutation. `Always` fits every outbound request in the invocation. Explicit user reruns are separate invocations, subject to Marshall's own request-key rules.

Source: `porsche/lib/porsche/runner.ex:10-16,58-89` allocates ID before submission and calls `submit` once; `:92-106` assigns a mutation request ID; `:125-164` polls with `request show`, tolerates transient errors and validates operation ID. `:168-203` validates closed receipt shape and physical operation identity. `porsche/lib/porsche/client.ex` is the verified API transport. ADR-0101 and source contract define expected semantics, not a current Antithesis pass.

History/oracle: connect packaged Porsche SSH CLI to real Marshall HTTP command endpoint. An external request recorder at the Marshall ingress counts command names and request IDs independent of Runner state; PostgreSQL operation/receipt rows and real guest effect history establish what actually happened. Admit a physical mutation, lose the first HTTP response or each poll response, return stale or mismatched operation receipts through a controlled transport fault, and kill/restart the CLI. Assert no second mutating POST within one invocation; the subsequent explicit `request show <id>` is read-only. A transport timeout cannot be reported as physical failure or success without a terminal receipt.

Progress guidance: on a workload that guarantees one accepted mutation, stable authority and a finite fault-free tail shorter than configured CLI timeout, `Sometimes(matching_terminal_receipt_seen)` **"Porsche wait observes matching terminal receipt after transient polls"**. This is nontrivial semantic progress with an explicit precondition. `Reachable` **"Porsche continued authorized polling after transient error"** at `poll/2:156-157` is a replay anchor. Never log command arguments, SSH tokens or response bodies; use request/operation IDs and closed statuses.

Value menu: timeout 1/2/120 seconds; poll failures 0/1/3; accepted/succeeded/failed/superseded receipts; matching/wrong operation ID; first response delivered/lost; one/two explicit CLI invocations. Hosted real Porsche SSH, Marshall HTTP/PostgreSQL and a deterministic effect fixture cover the command count; native guest effect truth requires native machine execution. A mock request callback alone is insufficient.

Open questions: Which Marshall ingress capture can count actual mutation submissions without recording secret command fields? Can the chosen physical command complete within a controlled no-fault tail and the CLI timeout in hosted TCG?

### Investigation Log

#### How can ingress count without secrets?

- Examined: `Runner.submit/2:108-122`, `Porsche.Client` and runner diagnostic contract at `:217-223`. Found: command name and request ID are structured fields; arguments can contain secrets. Not found: an existing sanitized ingress counter. Conclusion: add observer metadata extraction at a safe request boundary, not full-body logs.

#### Is conditional progress feasible?

- Examined: `Runner.await/2:125-137`, `poll/2:139-164`. Found: finite client timeout and continued poll on named transient errors. Not found: a hosted physical command completion bound. Conclusion: use controlled fixture initially; native/TCG progress requires measured completion within the configured tail.
