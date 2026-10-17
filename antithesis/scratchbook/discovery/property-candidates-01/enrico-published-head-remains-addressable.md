# enrico-published-head-remains-addressable

P1; medium-high confidence; safety. Planned SDK instrumentation is **missing** per the [fresh scan](../../existing-assertions.md). Proposed `Always` message: **"Enrico published Git head remains addressable through failed refresh"**. While Marshall retains published head SHA H for a registered repository, an interrupted or failed refresh must leave H resolvable and its controlled sentinel blob identical under an explicit SHA read. Check at each settled failed/refreshing state; `Always` fits a safety invariant. Do not assert `HEAD` still equals H: an in-progress fetch may update refs before Marshall publishes a new head.

Source: `enrico/lib/enrico/git.ex:47-99` constructs a fixed source and uses atomic fetch, retaining the previous and new default head under `refs/enrico/retained/`; `:101-115` resolves/retains a SHA. `enrico/lib/enrico/manager.ex:58-63,70-123` bounds attempt replay to process lifetime and makes refresh single-flight. `marshall/lib/marshall/enrico/repository.ex:15-49,70-76` preserves `head` across `:fail`; `marshall/lib/marshall/enrico/worker.ex:112-169` settles matching attempts and records outcome/audit transactionally. `marshall/lib/marshall_web/live/git_live.ex:28` defaults browsing to the published SHA. ADR-0097 and `marshall/lib/marshall/enrico/CONTRACTS` state the intended failed-refresh preservation.

History and independent oracle: use a local HTTPS Git fixture with two commits containing distinct sentinel bytes; publish H, force-push the fixture so H leaves the upstream branch, then cut Enrico during fetch, around retained-ref update, and before Marshall outcome settlement. Include transport failure and worker loss/retry. An observer stores H and blob hash outside Enrico/Marshall, reads Marshall's durable row/audit from a separate PostgreSQL connection, and executes `git cat-file`/`show` against Enrico's real bare mirror or uses the authenticated explicit-SHA API. A missing H or changed blob while H remains published is a violation. Marshall timeout/status uncertainty must be reconciled; removal and re-registration end the prior namespace and are excluded.

SUT guidance: `Reachable` **"Enrico retained prior published head across force push"** after `retain_head` on a prior H with changed upstream; `Reachable` **"Marshall settled failed Enrico refresh without replacing head"** at `Worker.record_outcome!/2` failure. These are positive branch anchors. Use repository/attempt IDs and SHA only in SDK metadata; never log repository contents or credentials.

Value menu: 1/2 competing attempts; 1/8 active repositories (configured manager cap); 2/3 upstream commits; unchanged/force-pushed branch; cut before/after atomic fetch and `update-ref`; lost worker/status reply; restart before/after receipt eviction. Hosted real Marshall/PostgreSQL/Enrico/native Git plus local TLS source fixture cover Git object availability; physical ZFS durability and cross-host cache survival require native execution. A failed refresh may leave an updated unpinned branch; explicit published SHA remains the oracle.

Open questions: Does the authenticated browser/raw endpoint consistently pass explicit published SHA for all read routes, or is direct Git inspection required for this invariant? What harness hook gives a deterministic cut within the native Git helper's atomic fetch/retained-ref sequence?

### Investigation Log

#### Do all read routes pin the published SHA?

- Examined: `marshall/lib/marshall_web/live/git_live.ex:28`, `marshall/lib/marshall_web/controllers/git_raw_controller.ex:15`, and `Catalog.inspect/4:112-124`.
- Found: LiveView defaults to `repo.head`; raw controller defaults to `HEAD`, which may be mutable. Explicit SHA works as the common property precondition.
- Not found: a universal published-head rewrite at Catalog boundary.
- Conclusion: use explicit H for this core invariant; raw default-HEAD semantics are a separate potential product issue, not a confirmed defect here.

#### Can native Git be cut at exact substeps?

- Examined: `enrico/lib/enrico/git.ex:56-89` and manager task invocation at `manager.ex:89-109`.
- Found: refresh invokes argv Git calls in a supervised task.
- Not found: a built-in substep fault hook.
- Conclusion: use process/transport kills for broad windows; a targeted safe failpoint would improve branch guidance after a green baseline.
