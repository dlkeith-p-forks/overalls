---
sut_path: /home/ghuntley/src/overalls-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
focus: "05 — Resource Boundaries"
---

# enrico-native-git-admission-after-manager-restart

**Claim, priority, confidence.** P1 safety, high confidence in intended physical limit. Across Manager/task supervisor replacement, at most eight Git utility ownership trees may execute and one repository may have only one mutating refresh. Proposed unique assertion: Always("enrico native Git descendants never exceed inherited admission slots", distinct_live_slot_lock_owners <= 8 && per_repository_live_mutators <= 1). It is missing per ../../existing-assertions.md. A Reachable("enrico ninth refresh receives admission refusal while eight native slots remain held") is a valid saturation target.

**Source and history.** enrico/lib/enrico/manager.ex:8-24 sets eight active refreshes and 1024 retained completed receipts; handle_call refresh at :65-124 checks replay, per-repo busy and global saturation before starting a task. enrico/lib/enrico/refresh_supervisor.ex:8-20 couples Manager and max_children=8 Task.Supervisor under one_for_all. enrico/native/git-owner/src/main.rs:70-110 acquires non-followed stable lock inodes and one of eight process-held .enrico-git-slot-N.lock files; :138-190 guards child custody and streaming. The source history in enrico/native/git-owner/tests/histories.rs exercises helper death and descendants, but a current hosted full stack result is missing. A Manager count after replacement is insufficient because old utility descendants may survive BEAM loss.

**Workload and oracle.** Create nine independent repositories with local deterministic Git fixtures, each refresh blocked after native utility exec. Hold eight actual flock slots, lose the BEAM Manager or task owner, and request a ninth plus a second attempt for one held repository. Inspect /proc process ancestry, opened lock inodes/flock ownership and actual Git command accept times, not only Manager.active. Release one descendant and verify a new eligible refresh can begin during a healthy quiet interval. If cleanup remains uncertain, conservative refusal is correct. Manager receipt eviction/restart legitimately ends its local replay namespace; durable Marshall intent is a separate concern.

**Limit menu.** 7/8/9 concurrent distinct repository attempts, duplicate and different attempt on same repository, result-before-task-exit gap, caller/helper death and grandchild-held lock. Git output maximum and timeout must be configured to keep fixtures finite.

**SUT guidance and limits.** Add markers after native slot flock and utility exec, and before Manager reply; preserve original lock inodes for observer. Hosted Linux needs flock/inherited-FD/subreaper behavior; fake task completions cannot validate physical bound. Open questions: Does the selected hosted kernel preserve the exact inherited descriptor/descendant custody semantics? Can local fixture routing satisfy production source-origin restrictions without weakening them?

**Architecture/HLDD impact.** No production change or ADR status update; this tests existing Enrico native ownership.
