---
sut_path: /home/ghuntley/src/kittens-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
---

# Focus 08 — Lifecycle transitions

The seven candidates below target distinct transition guarantees. `Always` checks exact positive transitions; `Sometimes(cond)` requires meaningful recovery after faults heal; `Reachable` marks a specific useful branch outcome. Proposed message strings are unique and detailed in linked evidence. The fresh [existing-assertions scan](../existing-assertions.md) found no Antithesis SDK assertions in current SUT source, so every planned assertion is **missing**. These are properties to test, not claims of verified behavior or confirmed defects.

### healthy-revision-requires-live-candidate — Healthy revision reflects the active candidate

| | |
|---|---|
| **Type** | Safety and reachability |
| **Priority / Confidence** | P0 / high |
| **Property** | A new `lastHealthy` revision names the exact active closure after current candidate secret preparation and bounded affirmative health of enabled roles. |
| **Invariant** | `Always` at every new healthy advancement compares revision, closure, current secret material and health; `Reachable` marks the verified identical-closure/current-secrets branch. These fit a must-hold transition and a rare successful outcome, respectively. |
| **Antithesis Angle** | Interrupt stage, switch, secret-unit restart and consecutive health checks; change encrypted secret source at the same closure or fail a private role endpoint. |
| **Why It Matters** | A false healthy receipt could bless a host using old credentials or failed control/ingress services. [Evidence](property-candidates-08/healthy-revision-requires-live-candidate.md). |

**Open Questions:** None.

### migration-finishes-before-upgrade-activation — Explicit migration precedes activation

| | |
|---|---|
| **Type** | Safety and reachability |
| **Priority / Confidence** | P1 / high |
| **Property** | A candidate serving closure activates only after its explicit candidate migrator succeeds; plain serving startup does not migrate, and failed health never triggers schema rollback. |
| **Invariant** | `Always` checks migration completion before activation; `Reachable` marks a second real migrator waiting on the advisory owner. The first is mandatory order, the second a useful concurrency branch. |
| **Antithesis Angle** | Kill an updater while its systemd migrator survives, race two Marshall hosts on one PostgreSQL primary, and interrupt around schema commit. |
| **Why It Matters** | Serving new code on an unprepared schema or racing DDL can break the control plane. [Evidence](property-candidates-08/migration-finishes-before-upgrade-activation.md). |

**Open Questions:** None.

### upgrade-preserves-owned-guests — Upgrade preserves physical guest custody

| | |
|---|---|
| **Type** | Safety and liveness |
| **Priority / Confidence** | P1 / high |
| **Property** | Lilly release and credential-only upgrades preserve unrelated guests' VMM and disk identities while the new release resumes authenticated control. |
| **Invariant** | `Always` compares physical PID/start-time/cgroup and disk GUID through each upgrade for control guests; `Sometimes(cond)` requires a healthy upgraded release, fresh host session and guest traffic through the same VMM after faults heal. |
| **Antithesis Angle** | Interrupt before/after consumer restart or switch, rotate same-closure credential bytes, and delay reconnection. |
| **Why It Matters** | Control-plane upgrades must not destroy running user work. [Evidence](property-candidates-08/upgrade-preserves-owned-guests.md). |

**Open Questions:** None.

### runtime-restart-requires-fresh-readiness — Restart cannot inherit readiness

| | |
|---|---|
| **Type** | Safety and liveness |
| **Priority / Confidence** | P1 / high |
| **Property** | A restarted Lilly Runtime needs a new authenticated, delivered report and current actor reconciliations before exposing readiness, while surviving guests rejoin after recovery. |
| **Invariant** | `Always` checks every new-incarnation true readiness against current session/report and commands; `Sometimes(cond)` requires reauthentication, true readiness and unchanged VMMs after the database heals. |
| **Antithesis Angle** | SIGKILL Lilly one or two times during a PostgreSQL outage and restore database service across the 15-second report freshness boundary. |
| **Why It Matters** | Stale journals cannot safely certify new control authority; recovery should retain existing guests. [Evidence](property-candidates-08/runtime-restart-requires-fresh-readiness.md). |

**Open Questions:** None.

### guest-readiness-binds-current-physical-boot — Readiness follows the current boot

| | |
|---|---|
| **Type** | Safety and liveness |
| **Priority / Confidence** | P0 / high |
| **Property** | A guest-ready running outcome must match current placement, epoch, generation and physical boot after authority is rechecked on both sides of guest waiting. |
| **Invariant** | `Always` compares every positive readiness/outcome receipt to the current boot and command; `Sometimes(cond)` requires a new physical boot to reach matching accepted readiness after a recovered interruption. |
| **Antithesis Angle** | Replace a VMM or advance generation while a vsock readiness response is delayed, then replay an older trust or boot response. |
| **Why It Matters** | Stale boot readiness can authorize access to the wrong or no guest. [Evidence](property-candidates-08/guest-readiness-binds-current-physical-boot.md). |

**Open Questions:** None.

### stop-retains-disk-until-restart — Stop removes execution, retains workload

| | |
|---|---|
| **Type** | Safety and liveness |
| **Priority / Confidence** | P1 / high |
| **Property** | A completed stop has no running VMM or network attachment but retains the same disk and address, which a fresh start can use again. |
| **Invariant** | `Always` checks each accepted stop completion against native absence and retained disk GUID/address; `Sometimes(cond)` requires a new boot from the same disk after healed interruption. |
| **Antithesis Angle** | Interrupt between non-running intent, unit exit, network detach and accepted physical outcome; retry stop/start. |
| **Why It Matters** | Early compute release risks overcommit; disk loss destroys stopped user data. [Evidence](property-candidates-08/stop-retains-disk-until-restart.md). |

**Open Questions:** None.

### delete-release-follows-physical-retirement — Delete releases only proven absence

| | |
|---|---|
| **Type** | Safety and liveness |
| **Priority / Confidence** | P0 / high |
| **Property** | A delete cannot archive the VM or free reservation/address until exact-current VMM, network and disk cleanup is physically confirmed and accepted. |
| **Invariant** | `Always` checks each archive/release against matching accepted deleted outcome and independent native absence; `Sometimes(cond)` requires an initially unconfirmed cleanup to reach confirmed retirement after faults heal. |
| **Antithesis Angle** | Fail unit stop, network detach or ZFS deletion; crash actor before/after outcome journal and acknowledgement; replay an old generation. |
| **Why It Matters** | Premature reuse can overlap old effects or lose deletion custody. [Evidence](property-candidates-08/delete-release-follows-physical-retirement.md). |

**Open Questions:** None.

## Breadth, limits and architecture impact

Inspected Marshall serving/operator startup and Compute lifecycle/outcome mutation; Lilly application supervision, Runtime restart/readiness, VM actor, executor and driver boot/stop/delete paths; Nix updater state machine, secret staging, migrator, activation and health; accepted ADR-0017/0036/0140/0149 claims; current native fleet lifecycle, updater and runtime-readiness scenario files; and local source `CONTRACTS`. The existing assertion scan remains the source of truth for instrumentation status. I did not treat diagnostic delivery as a lifecycle gate or serving startup as an implicit migration path. A client timeout is uncertain effect, not a proven refusal or defect.

The focus only writes research under `discovery/`; it changes no API, architecture decision or implementation. The relevant accepted decisions remain ADR-0017 (durable ownership), ADR-0036 (updates/migration), ADR-0140 (physical liveness), and ADR-0149 (independent diagnostics). Hosted real-service checks can validate control and database order; TCG guest/storage can validate actual boot and disk effects but not Firecracker isolation; native KVM/NixOS is needed for full VMM/cgroup and systemd/ZFS claims. Source and test presence do not establish a fresh hosted baseline, native campaign, or confirmed defect. The independent physical oracles, fault preconditions, bounded values and instrumentation seams are in each candidate file.
