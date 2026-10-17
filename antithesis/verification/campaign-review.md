# Campaign admission and identity review

Source review on 2026-10-13, updated for the current ledger admission code and five-attempt bootstrap admission. Scope: `campaign.py`, `identity.py`,
`selection.py`, `assertions.py`, their tests, selected Compose profiles, and the
workload Docker stage. No remote run was submitted. The global ceiling is
intentionally `5N`, where `N` is the union of researched primary safety messages
and authored safety messages across profiles. Missing selected callsites remain
coverage gaps; they do not shrink that authorized ceiling or establish a pass.

## Resolved findings in the inspected update

1. **Baseline and mutant identities are now separate.** `campaign.py`'s
   `initialize` path
   preserves a green baseline only when a reviewed patch receipt names that
   baseline, the new exact mutant identity, the same harness scope and an
   authored target. Its `reserve` path carries baseline and patch hashes on
   each mutant attempt. The CLI checks the supplied patch bytes against its
   receipt during initialization. This binds the operator-reviewed patch;
   it does not independently prove the patch's semantic effect.

2. **Catalog-only mutant targets are now refused.** The CLI obtains selected
   authored safety messages from the frozen assertion roster during
   initialization; `reserve` requires the target in that
   list and in the exact mutant patch receipt. The full researched catalog
   remains in global `N` as intended.

3. **Submitted runs retain their in-flight slot.** `campaign.py`'s `transition`
   permits abandonment only while reserved. A submitted attempt remains active
   until a completion transition. `reserve` now refuses a second baseline for
   the same Compose config while its first baseline is reserved or submitted,
   before clearing any existing green lineage. A different config can reserve
   a baseline within the global five-active and attempt-ceiling limits. Once
   the first baseline is abandoned before submission or completed, another can
   be reserved. Mutant, retry and resweep selection is serialized while one of
   those attempts is reserved; submitted attempts remain subject to the global
   five-active limit.

4. **Rendered service tags and workload code are checked.**
   `identity.py`'s `selected_stages` requires each rendered service image tag to
   match its inspected build stage. Its `verify_image_copies` and
   `verify_image_selection` compare the copied workload tree and bytes,
   including unselected modules, with the inspected image.
   `selection.py`'s `verify_materialization` binds the hosted graph to those
   inspected image IDs. The verifier also compares the checked Nix rootfs
   against the final image after later Dockerfile copies.

5. **Campaign durations are now bound at every ledger transition.**
   `campaign.py` assigns 60 minutes to baseline attempts and 15 minutes to
   bootstrap, mutant, retry and resweep attempts when reserving. Submission
   requires an explicit matching duration, and completion requires an explicit
   matching observed duration; both values are retained in the attempt record.
   Missing, conflicting, tampered or mismatched durations fail closed. The
   verification README documents the operator commands and aliases.

## Remaining limitation

The rootfs comparison excludes only engine-generated pseudo-filesystems and
container-injected paths (`/dev`, `/proc`, `/sys`, selected `/etc` files,
`/run/.containerenv` and `/var/tmp`); those mounts are not image-layer
evidence. The separate Dockerfile copies and workload tree remain checked
independently.

The green receipt is deliberately operator-derived from Antithesis triage, as
`README.md` states. `campaign.py`'s `transition` checks its run ID and local identity
fields but cannot authenticate the remote property results, setup completion,
or execution scope. This trust boundary must stay explicit in acceptance
reports; a locally accepted receipt alone is not remote proof. The review does
not request a new remote attestation service.

Architecture impact: this review changes no runtime behavior or accepted ADR.
It records verification gaps against the existing immutable-run-identity and
remote-attempt-admission contracts. No HLDD section changes are indicated by
this read-only review artifact.
