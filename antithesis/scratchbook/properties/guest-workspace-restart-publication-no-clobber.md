# guest-workspace-restart-publication-no-clobber

P1; high confidence; safety. Instrumentation **missing** per [fresh scan](../existing-assertions.md).
`Always(accepted source survives restart unchanged; completed published checkout
is never recloned/overwritten by recovery, even if done marker was not published)`;
message **"Guest workspace recovery preserves its accepted source and published developer checkout"**.

Evidence: `lyra/src/workspace_receiver.rs:466-489` (`write_atomic`) fsync/rename;
`:550-594` (`start`, `deliver`) reads persisted source before done, accepts
identical redelivery and refuses conflicts; `:598-635` (`attempt`) deletes only
partial path, recognizes already renamed checkout, then publishes done. Crash
between rename and done is explicitly handled. Guest unit custody is defined in
`nix/packages/guest/private-services.nix:57-83`; immutable source protocol in
ADR-0128 and source revision updates. Lyra CONTRACTS forbid URL/ref/Git output
diagnostics. Accepted source is a reference; mutable branch resolution can change
before an unpublished partial retry, so do not promise a commit not yet resolved.

History: deliver real source and lose accepted reply, interrupt source fsync,
clone/fetch/partial cleanup, rename-before-directory-sync, sync-before-done, or
done-before-status. Restart receiver/guest. Add developer edit to published
checkout, then redeliver same/different source with moving upstream branch. Verify
existing bytes and no new Git effect after publication/done. A corrupt or obsolete
stored source should refuse rather than silently reset state.

Independent oracle: durable source bytes decoded by independent schema, actual
Git commit/tree/files, tagged developer modification, inode/content snapshots,
Git fixture effect ledger, done/status files. Check absence of success status when
unpublished/failed; `accepted` is source custody, not checkout completion.
Checkout pathname existence is not by itself proof Git content succeeded; initial
fixture must witness successful build of that checkout before interrupted marker.

Guidance: `Reachable` **"Guest workspace completed a done marker for an already published checkout after restart"**
only with independent prior rename/content witness; **"Guest workspace refused a conflicting redelivery after recovery"**.
Additional `Sometimes` **"Guest workspace resumed an accepted unpublished source and completed a real checkout"**
checks actual expected bytes under finite source outage, valid credentials and
remaining configured attempt budget. Main Always is safety, supplementary
Sometimes is conditional progress, not a claim arbitrary unavailable Git must work.

Values: first/same/conflicting source; partial/renamed/done states; retry attempt
0/9/10 at production ten-attempt RetryPolicy (`workspace_receiver.rs:444-446`);
source absent/valid/corrupt;
branch unchanged/moved; SHA1/SHA256 object formats. Real Rust/files/Git hosted
exercise local publication; genuine TCG guest/rootfs/vsock verifies guest restart
and handoff; native Firecracker boot isolation remains separate.

Open questions: How will the selected TCG executor retain one writable disk overlay across an actual guest power cut and prove the published checkout's bytes survived? `(partial: Lyra syncs the checkout directory before writing done and the native fixture checks retained files, but no hosted TCG restart action is assembled)`

### Investigation Log

#### How does a TCG restart preserve guest filesystem and independently witness rename durability?

- Examined: `lyra/src/workspace_receiver.rs:466-489,550-635`, `nix/tests/machines/repository-launch/guest.exs:35-57`, and `../deployment-topology.md` guest-vmm design.
- Found: the guest receiver renames the complete partial checkout, syncs the workspace directory, then writes `done` atomically. It treats a directory already present after restart as published and writes `done` without cloning again. The existing native guest probe checks retained checkout HEAD, its local marker, `done`, and absence of partial path after a restart. A hosted TCG probe needs the same writable qcow2 overlay and independently recorded overlay/boot identities before and after a power cut, plus guest file bytes and HEAD after remount.
- Not found: a built hosted QMP/power-cut action with a retained overlay and a pre-crash witness at the rename/directory-sync boundary.
- Conclusion: partial harness task. Receiver status alone cannot establish durability; verify the same overlay and actual bytes across reboot, with native Firecracker scope kept separate.

#### Source hypothesis: can an unrelated pre-existing checkout directory be mistaken for publication?

- Examined: `lyra/src/workspace_receiver.rs:598-635` and the async handoff in `lilly/lib/lilly/vm/executor.ex:467-495`.
- Found: `attempt` regards any directory already present at `/workspace/<repository>` as `finished`, skips Git and writes `done`; this branch does not check Git HEAD or a source-bound publication marker. Because VM readiness is independent of clone delivery, the code permits a scheduling window in which another writer might create that path first.
- Not found: a current real-guest reproduction with a competing writer, or proof that another component prevents that path from existing before delivery.
- Conclusion: source-grounded defect hypothesis, not a confirmed runtime defect. Include a pre-existing foreign-directory value and independent HEAD/content oracle in a future owned fixture; a `done` marker alone would hide this case.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: guest boot/source/HEAD/done marker and independent Git or file bytes; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R5`: Add a unique SUT-side `Reachable` or `Sometimes` at the observed intermediate commit/effect before uncertain reply. Requested faults alone are not reached checkpoints; retain the independent final `Always` oracle. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
