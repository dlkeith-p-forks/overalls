# guest-workspace-restart-publication-no-clobber

P1; high confidence; safety. Instrumentation **missing** per [fresh scan](../../existing-assertions.md).
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

Open questions: How does the selected TCG restart action preserve guest filesystem
and independently witness rename durability without relying on receiver status?
