# Private guest CLI updates

## Scope and architecture impact

This change gives the NixOS and Ubuntu guest images an immutable Lyra seed
supervisor and a root-owned managed executable. It adds fixed private artifact
routes to Ziggy, current-execution authorization in Marshall, and a digest on
executor registration. It changes private API, persistence, recovery and guest
execution boundaries under ADR-0096, ADR-0100 and new ADR-0104. The public
desktop CLI updater retains its existing source and activation behavior.

## Review findings

- The guest fetch path is fixed to `llm.internal`; Ziggy accepts only an
  Audi-derived binding and asks Marshall to validate the host and current VM
  execution. Ziggy hashes its Nix-packaged binary and compares it with
  Marshall's selected release before serving either route. A release mismatch
  returns unavailable. A guest cannot supply an artifact URL, digest or path.
- The supervisor seeds locally and starts the executor without waiting for
  the artifact service. Updates verify a 100 MiB bound and SHA-256 digest,
  stage an executable in the managed directory, then request graceful executor
  exit. The prior inode remains linked until the replacement registers with
  Marshall; a failed registration restores it. A reboot after an incomplete
  handoff reconciles the saved previous executable. A replacement that
  registers and later malfunctions is outside this recovery contract, as
  authorized in ADR-0104.
- Marshall keeps the reported digest on each fenced executor session and
  writes a content-free audit receipt on a changed digest. The receipt is in
  the same transaction as registration. The digest is an observation of the
  guest process; it is not an attestation of what code a compromised guest ran.
- Existing VMs are excluded from this rollout. Both new images carry private
  trust, a seed and the same systemd service semantics. The Ubuntu assembly
  VM needs 12 GiB of build memory to hold its pinned Nix closure in tmpfs.

## Verification

- Lyra Rust tests and Clippy pass, including properties for digest, path,
  staging and rollback behavior.
- Marshall and Ziggy `mix precommit` gates pass, including their test suites,
  forced Dialyzer, logging and contract checks.
- Repository `prek run --all-files` and `elixir scripts/check_adrs.exs` pass.
- Both NixOS and Ubuntu Firecracker fleet checks pass: private delivery, a
  periodic update after reseeding the old executable, shared-user prompt
  wakeup, fenced tool work and capability denial all complete.

## Remaining gaps

The audit digest cannot prove guest integrity. Registered-but-bad software has
no automatic semantic rollback by decision. The first live host deployment and
new guest creation remain operational evidence after the code is merged.
