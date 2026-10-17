# Guest dataset streams in lilly-hostd

## Scope and architecture impact

This review covers [ADR-0183](../decisions/0183-guest-dataset-streams-in-hostd.md),
which replaces [ADR-0182](../decisions/0182-unprivileged-lilly-beam.md)
step 3 (ZFS delegation to the unprivileged `lilly` user) with one typed
lilly-hostd request, `TransferStream`. The change touches:

- the hostd protocol (op 11) and its utility table;
- the `lilly-transfer-stream` CLI (no lock, no stdin channel, a progress
  descriptor, per-side uids);
- Lilly's stream client and the producer and consumer descriptors it builds;
- the NixOS Lilly module (delegation revoked, fixed uid and gid);
- the machine-test fixtures that drove the old argv interface.

Domain boundaries are unchanged. The authorization and isolation boundary
moves: the BEAM loses every ZFS permission.

## Findings

1. **Delegation was a privilege hole and did not work.** A throwaway-pool
   experiment showed that a delegated, non-root `zfs receive -o …` exits 0
   but drops every non-user property. The result is a dataset Lilly's
   verification refuses (the observed `received_dataset_unconfirmed` in the
   unprivileged cross-pool clone). The same delegation lets any `lilly` uid
   process receive a crafted stream: the dataset inherits `setuid` and
   `devices` and is mounted at the next boot. Fixed by ADR-0183: hostd
   derives every command from validated fields with the fixed receive
   policy.
2. **The fixed uid 977 collided on dungarees.** NixOS allocates system uids
   downward from 999. On dungarees, 977 already belonged to an OTel request
   exporter (`ksx-…`). With `uid = 977`, hostd's peer check would have
   admitted that exporter as Lilly, and the two users would have shared file
   ownership. This was never deployed. Lilly now uses uid and gid 377, below
   the dynamic range and unassigned in nixpkgs' `ids.nix`. Both hosts were
   checked and have no user or group 377. The gid is now fixed as well,
   because hostd chowns lease files to `uid:uid`.
3. **Parent-death signal ordering.** The helper set `PR_SET_PDEATHSIG`
   before dropping a side to the service uid. Linux can clear the signal on
   a credential change, so the helper now sets it after the drop. On Linux
   6.18 a manual check found the old order also killed the side, so the new
   regression test (`unprivileged_sides_die_with_a_killed_helper`, run as
   root) guards the outcome rather than discriminating the order.
4. **The SSH client runs unprivileged.** The plan's root `ssh` with
   fd-passed key files was replaced: `ssh` and `cmp` run as the service uid
   with no supplementary groups and `no_new_privs`, and read Lilly's own key
   files. Only the ZFS sides are root. A root hostd serving another uid with
   no service uid refuses those sides. A root caller's private daemon keeps
   its own uid, which grants nothing the caller lacks.
5. **Main's Nix layout move left broken paths.** The `nix/` reorganization
   on main (`ee3789e83`) left relative paths pointing at old locations, and
   neither host system evaluated. Examples: patch paths in
   `infrastructure/firecracker.nix` and `toolchain.nix`, `secrets/` from
   `platform/hosts/profile.nix`, the `repositoryRoot` default, the source
   roots, the machine tests' `modules/` imports, and four documentation
   links. They were repaired mechanically: each broken literal was resolved
   against the file's old location and mapped through the rename list, and
   one-level depth errors were corrected where exactly one candidate
   existed. Both host systems now evaluate.

## Verification

- `lilly-hostd`: 36 tests passed, including the exact derived argv for each
  producer and consumer, out-of-grammar refusals, a Hegel decode round trip,
  real `ssh -G` resolution of the fixed options, the daemon running the
  helper under a lease, and the resume-token gate. Clippy and rustfmt are
  clean.
- transfer-stream: 10 integration and 3 unit tests passed (8 fixtures are
  ignored by design), plus `unprivileged_sides_die_with_a_killed_helper`
  run as root. Clippy and rustfmt are clean.
- Lilly transfer and clone suites: 131 passed (12 properties, 119 tests),
  through a private hostd with the packaged helper.
- `dungarees` and `overalls` system toplevels evaluate (`nix build
  --dry-run`).

## Gaps

- No native machine run is recorded yet for the zfs-guest cross-pool clone,
  zfs-transfer, export-endpoint (pull, partial receive, resume, blocked
  sender cancellation) or ssh-transfer with the typed streams.
- No machine test asserts that `zfs receive` as `lilly` is refused on a
  deployed pool, or that `zfs allow` lists nothing for `lilly` after
  `lilly-ownership` runs.
- The zfs-transfer fixture's receive argv mirrors hostd's derivation. It does
  not exercise hostd; hostd's derivation is pinned by its unit test and
  exercised end to end by the clone and export-endpoint journeys.
