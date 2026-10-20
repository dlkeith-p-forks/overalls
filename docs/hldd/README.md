# HLDD review workflow

The handbook is maintained through explicit reviews of individual source files
and chapters. Run these commands in `devenv shell`:

```sh
elixir scripts/check_hldd.exs status
elixir scripts/check_hldd.exs record marshall no-impact 'Explain why the inspected source change preserves the documented behavior' --path marshall/lib/example.ex
elixir scripts/check_hldd.exs record marshall updated 'Describe the changed behavior and the corresponding chapter update' --path marshall/lib/example.ex --path marshall/priv/hldd/02-control-plane.md
elixir scripts/check_hldd.exs
```

The example source path is illustrative. Select actual stale paths reported by
`status`. Omitting `--path` records every stale target in that group and therefore
requires reviewing every one of those changes. A check never changes files.
Current receipts are untouched even if included in a recording command. An
`updated` source review may cite a selected chapter already reviewed since that
source’s previous receipt; the chapter receipt is not rewritten. Reusing the same
chapter version for another later source change requires `no-impact`.

## Files and review boundaries

| Location | Responsibility |
| --- | --- |
| `groups/<group>.yaml` | Stable source prefixes and relevant chapter filenames; one catch-all group covers otherwise unmatched files. |
| `reviews/sources/<repository-path>.md` | One receipt per source path, with `.md` appended to the full filename. |
| `reviews/chapters/<chapter-id>.md` | One independent receipt per chapter. |
| `marshall/priv/hldd/scenarios/<id>.yaml` | One scenario, with its exact evidence and remaining gaps. |
| `marshall/priv/hldd/topology/<host>.yaml` | One generated allowlisted deployment projection per host. |

Receipt YAML frontmatter contains the schema version, target identity, current
content hash, applicable mapping fingerprint, review disposition and the chapter
hashes inspected during the review. The Markdown body contains the concrete
rationale. There are no timestamps or global receipt index to conflict over.

Source hashes bind the path as well as bytes. Adding, editing, renaming, deleting
or restoring a source requires review. Deletion records a tombstone at its existing
receipt path; a tombstone does not authorize a restored file. A removed chapter
with no remaining group mapping is reviewed through the catch-all group. Changing applicable
group definitions requires reviewing the affected sources again. Chapter hashes
in source receipts are historical review context, not a requirement to repeat all
source reviews whenever documentation changes. Each chapter's own receipt checks
its current bytes. Missing chapters, invalid references, scenario evidence errors
and stale generated views still fail independently of receipts.

## Concurrent work

Two agents changing different source files update different receipts, even in the
same group. A documentation change updates its chapter receipt once. Use explicit
path selectors when another agent has unreviewed work in the same checkout.

When both branches change the same source or chapter, resolve the actual content
first and review the result. A receipt from either parent cannot approve different
merged bytes. Run `status`, inspect the combined diff, and record the affected
paths. Never use an automatic merge driver to approve evidence or choose a receipt
only to make a check pass. Regenerate topology and scenario chapters from combined
source records when necessary.

## Migration from the aggregate JSON

The one-time migration command takes an unchanged checkout containing the old
manifest:

```sh
elixir scripts/check_hldd.exs migrate /absolute/path/to/legacy-checkout
```

Every old group's source and chapter digests must match that checkout before any
receipt is written. Migration preserves the old rationale and hashes as provenance
and records the baseline's bytes, never the destination's changed bytes. The
destination must not already contain a receipt store. Run `status` afterward and
review migration/tooling changes and any other destination differences explicitly.
Normal checks reject the presence of `docs/hldd-maintenance.json`; there is no
fallback to the old format. Older branches must reconcile their actual changes
with the new receipts rather than restore the deleted aggregate JSON.

YAML uses the pinned PyYAML safe parser supplied by the development shell and Nix
gate. Keys must be unique strings; aliases, anchors, custom tags and non-JSON
scalar types are refused. Receipt rationales are Markdown prose outside YAML.
Formatting and writes are deterministic; complete files are replaced atomically.

These checks establish review currency and structure, not factual accuracy or
native execution. The [maintenance skill](../../.agents/skills/hldd-maintenance/SKILL.md)
still requires source inspection and appropriately scoped evidence.
