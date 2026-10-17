# enrico-published-head-remains-addressable

P1; medium-high source confidence; safety `Always`, message **"Enrico published Git head remains addressable through failed refresh"**. Missing SDK instrumentation per [scan](../existing-assertions.md). While Marshall still publishes immutable commit H, an interrupted/failed refresh must leave H resolvable with the same controlled tree/blob bytes. The guarantee concerns explicit H, not mutable `HEAD` or every branch ref; source inspection found the raw controller can default to `HEAD`.

## Evidence and fault history

`enrico/lib/enrico/git.ex:47-115` uses atomic fetch/new-clone staging and retains old/new default commits under `refs/enrico/retained/`. `manager.ex:58-123,171-222` makes attempts single-flight but ends local receipt retention on restart/eviction. `marshall/lib/marshall/enrico/repository.ex:15-76` retains published head on failure and `worker.ex:112-169` settles matching attempts. Force-push a local Git fixture from A to B, interrupt fetch, ref update or reply, kill BEAM/native owner, and retry Marshall intent. A second fetch after Enrico restart is allowed; losing published A is not. [Focus 01](../discovery/property-candidates-01/enrico-published-head-remains-addressable.md) found the explicit-SHA oracle; [focus 03](../discovery/property-candidates-03/enrico-interruption-preserves-published-head.md) added new-clone and restart windows.

## Oracle, environment, and instrumentation

The fixture records A's SHA and blob hash before refresh. Independent PostgreSQL reads establish Marshall's published H; direct `git cat-file`/`show` of Enrico's bare mirror or an authenticated explicit-H read proves availability and content. A failed response alone is not settlement. Hosted real Marshall/PG/Enrico/native Git can cover this; native physical storage durability is separate. Vary old/new clone, default branch move, 1/8 refreshes, reply loss, and receipt retention around 1024. `Reachable` anchors distinguish old published H retained after force push and failed Marshall outcome without head replacement.

## Open questions

- What observation/fault seam can reliably kill a real Git command between atomic fetch and the next retained-ref update without replacing the production Git executable? Transport and process kills cover broader windows, but no precise substep trigger is implemented.

### Investigation Log

#### What safe hook can interrupt real Git between atomic fetch and retained-ref update?

- Examined: `enrico/lib/enrico/git.ex:52-115,392-443`, `enrico/native/git-owner/src/main.rs:159-190`, and `nix/verification/tests/machines/enrico-service/driver.py:214-237,275-325`.
- Found: `retain_head(previous)` precedes `git fetch --atomic --prune`; `retain_head(new)` follows `symbolic-ref HEAD`. Every Git command is a separate native owner invocation. Existing machine tests cover force-push, `git gc --prune=now`, source outage and paused fetch, but not a deterministic kill at the command boundary after fetch.
- Not found: a production substep hook or externally recorded boundary event for this exact interval.
- Conclusion: partial. A hosted observer could trace `execve` of the subsequent `symbolic-ref`/`update-ref` utility and trigger a kill, while checking old H via direct `git cat-file`; validate that such tracing works without altering execution. Broad process kills still test retention, but do not claim the exact window.

#### How can a deterministic local Git fixture preserve Enrico's fixed production source-origin boundary?

- Examined: `enrico/lib/enrico/git.ex:48-70`, `nix/verification/tests/machines/enrico-service/default.nix:12-40`, and `driver.py:17-21,214-237`.
- Found: the existing packaged Nix test resolves fixed `github.com` to its loopback verified HTTPS bare-repo fixture, with a trusted synthetic CA; it force-pushes and verifies an older SHA still resolves after pruning.
- Conclusion: resolved. Reuse that fixture pattern; do not add a caller-selected origin, protocol or URL.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `repository`. real-hosted-git-and-native-helper; independent witness: fixed-origin Git request log, bare mirror SHA/blob and original flock inode. Native companion: not required for this bounded claim. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

## Authored assertion snapshot

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/repository/scenarios.py:143`. Fixed native Git origin/blob plus Marshall worker and SQL head/audit; hosted origin/worker campaign unexecuted. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.
