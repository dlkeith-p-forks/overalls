# Public CLI delivery routes — 2026-09-25

## Scope and architecture impact

Marshall now exposes the public CLI installer at `/bin/install.sh`, the manifest
at `/bin/manifest.json`, platform binaries at `/bin/<target>`, and their SHA-256
digests at `/bin/sha256/<target>`. The installer, Nix manifest, desktop updater
and machine-page command agree on those paths. This changes a public delivery
interface within ADR-0096; the decision's rationale and its historical live
acceptance remain intact. ADR-0104's guest update service continues to use
Ziggy's private `/agent/v1/update/` routes.

## Findings and compatibility

- Marshall still serves files only from the operator-selected Lyra Nix store
  path and allows only four fixed platform targets. The installer and updater
  still verify SHA-256 and enforce their existing download bounds.
- The former `/overalls/` endpoints are removed. Already-installed desktop
  clients using that manifest URL need to run the new installer once to resume
  automatic updates. This is an intentional compatibility break authorized for
  this change; no installed executable or guest state migration is required.
- Public route movement does not change Audi authorization, SSH key handling,
  or the private guest update authority boundary.

## Validation and remaining gaps

The focused Marshall controller tests pass for the new installer path, Bash
syntax, invalid targets, and old-route 404 responses. The full Rust tests,
Clippy, formatting check, and pinned Nix Lyra check pass. The Nix derivation
builds all four platform artifacts, and the manifest's paths, sizes and SHA-256
digests match those files. ADR structure and code-contract checks pass;
Marshall's complete precommit gate passes, including its test suite and forced
Dialyzer. A direct Marshall router probe against the final Lyra Nix package
returns the manifest, all four artifacts, and their matching checksums.
Live deployment and a production download of the new URLs remain unverified
until the pushed release is activated and observed.
