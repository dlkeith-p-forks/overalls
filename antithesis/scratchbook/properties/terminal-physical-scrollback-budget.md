---
sut_path: /home/ghuntley/src/kittens-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
focus: "05 — Resource Boundaries"
---

# terminal-physical-scrollback-budget

**Claim, priority, confidence.** P0 safety, high confidence in the claimed contract: concurrent creates and output growth must never allocate more live scrollback backing than the aggregate reservation, and a budget refusal must leave surviving PTYs and reservations intact. The important measurement is actual VecDeque allocation, not only ring_total. Proposed unique assertion: Always("terminal physical scrollback backing stays within reserved aggregate budget", physical_live_ring_backing <= ring_total && ring_total <= configured_total). A separate Reachable("terminal aggregate ring budget refuses a valid create while survivors stay live") guides saturation; it asserts the intended refusal branch, not a violation. Both assertions are missing in the fresh ../existing-assertions.md scan.

**Source and history.** nix/domains/artifacts/terminald/src/session.rs:16-35 sets 64 sessions, 1 MiB initial, 8 MiB per-ring and 64 MiB aggregate defaults. Daemon::create at :226-280 reserves before PTY spawn; grow_ring at :729-742 reserves the delta before limit growth; session_ended at :744-775 drops ring backing before quota release. reserve at :842 is an atomic checked update. nix/domains/artifacts/terminald/src/ring.rs:21-47 distinguishes allocated backing from logical retention and requires overwrite reuse. The local review docs/architecture/reviews/2026-10-05-terminald-growth-backing.md records a real local original-append mutant caught only after a two-phase output workload: 128 MiB allocated against 64 MiB reserved. That is sensitivity evidence for the old test, not a current defect or hosted result.

**Workload and oracle.** Use actual PTYs, helper output with an unambiguous completion marker, concurrent creates and growing writes. Keep each ring full after its final growth step; vary chunk sizes at 32767/32768/32769 bytes and include repeated overwrite. A test-only native observer can snapshot each live ring's VecDeque capacity, ring_total, session IDs and process identities under the existing locks. Independently inspect allocated backing rather than infer it from counter. At full ring quota, a valid create must refuse, live shell PID/start identities and output continue, and retirement must return backing before a replacement consumes quota. Retry after killed pump and with attached viewers. Preserve actual guest terminald service in TCG/native runs; a native PTY harness validates memory semantics but not Firecracker isolation.

**Limit menu.** Defaults 1/8/64 MiB plus generated 2/4/8 MiB maxima and aggregate exact-fit, one-byte-short and one-ring-free cases; raise session count when isolating ring quota. Reject impossible configurations before interpreting results.

**SUT guidance and limits.** Add branch/replay markers immediately after reserve refusal, successful growth and backing drop; do not use a mere logical ring length as oracle. Automatic faults may kill the daemon, which resets its in-process quotas and PTYs; compare only one daemon lifetime or capture physical teardown before successor admission. Open questions: How can hosted TCG read `VecDeque::capacity` for every live ring and the aggregate reservation from one coherent daemon snapshot? `(partial: Rust exposes allocated capacity only under cfg(test), not over the guest protocol)` Which guest-vsock fixture can preserve concurrent PTYs and their identities through outer faults? `(partial: local daemon tests exercise real PTYs, but no composed TCG fixture is present)`

**Architecture/HLDD impact.** Research assertion only; ADR-0082 and the terminal capacity contract remain unverified claims, with no production or handbook change.

### Investigation Log

#### Can hosted TCG expose exact ring backing snapshots without changing allocator behavior?

- Examined: `nix/domains/artifacts/terminald/src/ring.rs:1-58,85-118`, `session.rs:209-280,729-775`, and `main.rs:150-190`.
- Found: `Ring::allocated_capacity` returns the backing `VecDeque::capacity` only under `cfg(test)`; production `LIST` exposes live sessions but no ring allocation or `ring_total`. Reservation occurs before PTY spawn and growth, with quota released after backing drop. A guest-local test observer would need a coherent snapshot under daemon locks, with only numeric capacities and session IDs, or a separately built test binary that preserves the allocator and production service path.
- Not found: a current authenticated guest-vsock operation or hosted observer exposing physical backing across all live sessions.
- Conclusion: partial. Host RSS or logical ring length cannot substitute for exact backing; label local Rust test evidence separately from any future TCG snapshot.

#### Which guest-vsock path preserves concurrent PTYs under outer faults?

- Examined: `nix/domains/artifacts/terminald/src/main.rs:55-112,150-190`, `lilly/lib/lilly/terminal/vsock.ex:97-132,214-220`, and `../deployment-topology.md`.
- Found: authenticated host-CID vsock supports concurrent control connections and live inventory, so a workload can keep separate authorized sessions and compare IDs while faulting Marshall/Lilly. The daemon and PTYs live in the guest and should survive outer service interruption only when the guest-vmm remains alive.
- Not found: an assembled TCG guest terminal fixture with retained QEMU/backend identity and simultaneous PTYs.
- Conclusion: partial composition; outer daemon restart must not be interpreted as preservation if the guest itself restarted.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: guest PTY birth/token/deque/process/nonce observed independently of host reply; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.

## Authored assertion snapshot

**Authored assertion snapshot (2026-10-13 15:03 UTC):** Primary `always` message is present at `antithesis/workload/terminal/scenarios.py:296`. Real guest PTY output checks deque allocation against reserved ring backing; full-budget failed create does not independently identify refusal reason, and no integrated guest or hosted result exists. It is outside the currently staged control-core selection. This records source presence, not a passing hosted or native result.
