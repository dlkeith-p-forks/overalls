---
name: hldd-maintenance
description: Maintain the authenticated Overalls HLDD, Ash domain and deployment topology views, scenario and security coverage, generated configuration reference, and blocking review checks. Required for changes to documented behavior, configuration, protocols, architecture, operations, or test evidence.
---

# HLDD maintenance

The handbook is mandatory maintained product documentation. `/hldd` is its contents
page; `/hldd/SECTION` serves one section to any signed-in user. Its source is
`marshall/priv/hldd/`. Root `AGENTS.md` requires
this workflow for every relevant change. Installing or invoking this skill is not
proof that the handbook is current: complete its updates and run the blocking gate.

## Review the change

Read the actual diff, applicable contracts and current ADR supersession chain.
Use `docs/hldd/groups/*.yaml` to find affected chapters. Its directory groups
cover additions and deletions; the catch-all includes newly introduced subsystems.
Inspect both implementation and tests. Existing guides can be stale. Do not copy
historical implementation claims without checking current evidence.

Write short declarative technical prose in the style of a systems handbook. Cover
configuration, operation, expected results and failure/recovery limits. Use tables
for references and Mermaid for topology, state or sequence information. Preserve
stable chapter IDs and section URLs. Use `[label](#section-id)` for inter-section
source links; the compiler emits the corresponding `/hldd/section-id` URL.
Keep desired state, observed state, workflow phase and
cleanup authority distinct. New functionality must acquire a chapter or a clearly
identified section, not merely a review receipt.

## Scenarios, preferred tests and security layers

Update `marshall/priv/hldd/scenarios/<scenario-id>.yaml` for user-facing scenarios affected by the
change. NixOS machine integration tests and property-based tests are the preferred
evidence above other test forms. Use units for bounded logic; never present them
as proof of kernel, network, native guest, TLS, or physical recovery behavior.

Each scenario must name its user journey, authority boundary, expected refusal,
exact test path and inspected assertion, tested scope, and remaining gaps. Classify
evidence as machine, property, unit or manual. `present` means the test exists;
`recorded` additionally requires an existing execution record and exact supporting
text. Historical results must retain their revision and scope. Do not upgrade a
claim because a nearby test or structural check passed. `covered` requires recorded
native and property evidence for the stated scope; otherwise use `partial` or
`gap`. Missing preferred tests need a concrete explanation and next test.

Document sensitive operations explicitly. Trace the layers like an onion:
identity → authorization → authenticated transport → current execution fences →
guest/host isolation → native storage ownership → recovery authority. Every layer
needs coverage entries. For changed permissions, sharing, elevation, credentials,
terminals, ingress, deletion or recovery, state both the allowed path and refusal
of stale/foreign/expired authority. Identify untested boundaries by name. A new
security layer or operation needs ledger coverage even when no test exists.

Regenerate the scenario chapter after editing its ledger:

```sh
elixir scripts/hldd_coverage.exs --write
```

This generates prose, not verification evidence. Retain existing gaps unless actual
scoped results justify closing them. Do not run destructive scenarios on live hosts.

## Configuration and diagrams

Ash business domains and deployment topology are mandatory visual sections, each
with concise explanations. Keep `21-domains.md` and `22-topology.md` current in the
same change as their source. A Mermaid fence or refreshed receipt is insufficient.

For Ash, discover every literal `use Ash.Domain` and declared resource in application
`lib/` sources, including new applications. Explain each domain's responsibility,
resource ownership and authority; maintain an interaction diagram for meaningful
cross-domain paths. Distinguish domains from deployable services, generated resource
versions, coordinators and policy modules. Explain transactional authority and
Lilly's host-local ownership separately. If declarations become dynamic, extend
the source inventory check explicitly; do not silently drop them.

For deployment, inspect the host inventory, enrolled/base profiles, host imports
and service modules. Show physical host placement, public/private paths, state
stores and failure boundaries. Explain replicas, transport, credentials by role,
storage ownership, configuration entry points and recovery limits. Do not copy a
test fleet's replica count into the deployed fleet. Declared placement is not live
health or physical high-availability acceptance.

Regenerate and review both source-derived inventories:

```sh
elixir scripts/hldd_views.exs --write
elixir scripts/hldd_views.exs --check
```

The topology projection is a public-field allowlist in `scripts/hldd/topology.nix`;
extend its roles when adding a service. Never serialize whole NixOS configurations,
environments, credentials or runtime state. Generated ownership/placement diagrams
do not replace the maintained interaction diagrams and prose. Every discovered
domain and host needs a responsibility/boundary row, plus source-backed authority
and verification/gap explanations. Preserve explicit scenario and security-layer
evidence; prefer NixOS machine integration and property tests above other forms.

The ordinary gate compares current Ash source, host inventory and recorded topology
with the views. The Nix `hldd` check additionally evaluates actual role placement,
Marshall instances, fleet peers/addresses and admin SSH ports. Keep negative/property
tests for new or omitted domains/resources/hosts, changed placement and missing
diagrams/text even after review receipts are refreshed. Run the NixOS browser test
over both sections so generated diagrams are verified by the real renderer.

For Nix option changes, regenerate the evaluated declaration reference:

```sh
elixir scripts/hldd_options.exs --write
```

Review types, defaults and required configuration. Evaluation uses module
declarations, not enrolled machines or runtime secrets. Add operational explanation
when an option changes behavior. Never add credentials to examples.

Mermaid enters only through the pinned local asset bundle. Keep strict rendering,
no links, HTML labels or source directives. Validate every diagram and its textual
explanation; do not collapse an evidence boundary to simplify a graph.

Preserve the section delivery boundary: the index contains metadata only and a
section page sends exactly one chapter body. Never preload all bodies, render
off-page diagrams, or retain previous chapter hooks after navigation. Exercise
direct links, section switching, browser back, theme changes and revocation.
The NixOS browser check must visit sections individually and verify that old
content and diagrams disappear. Unit/property checks must keep unknown IDs out
of file selection. Preserve contained horizontal scrolling for wide diagrams.

## Record and enforce

Run `elixir scripts/check_hldd.exs status` first. It lists individual stale paths,
their review groups and relevant chapters. Review those diffs, then record only
your changes. Source receipts are Markdown with YAML frontmatter under
`docs/hldd/reviews/sources/<source-path>.md`; independent chapter receipts live
under `docs/hldd/reviews/chapters/<chapter-id>.md`. Do not edit hashes by hand.
A source receipt retains the chapter hashes inspected during that review; later
chapter edits require their own review and do not invalidate unrelated sources.
Deleted sources retain reviewed tombstones; restoring them requires another review.

After reviewing each affected source group, record explicitly:

```sh
elixir scripts/check_hldd.exs record GROUP updated 'Concrete description of the changed reader-visible facts and evidence'
elixir scripts/check_hldd.exs record GROUP no-impact 'Specific reason these source changes preserve the documented behavior and evidence' --path path/to/source
```

Never bulk-refresh receipts to make the gate green. `no-impact` is a reviewed
conclusion, not an exception for inconvenient edits. Source/chapter edits after
recording require another review of that path. `--path` is repeatable and limits
the operation to the named targets; omit it only after reviewing every stale path
in the group. `updated` requires a changed chapter in the selected review when
source changes are recorded. A selected chapter may already be current if its hash
differs from the chapter snapshot in the previous source receipt. Current receipts
are never rewritten.

Topology snapshots live in `marshall/priv/hldd/topology/<host>.yaml`. Regenerate
them with the view command; do not choose one side of a conflicting generated
projection without evaluating the combined Nix source. Scenario files are rendered
in stable ID order. Never restore the removed aggregate JSON files after a merge.
See [migration and merge guidance](../../../docs/hldd/README.md). The checker is read-only and rejects stale
receipts, missing chapters, broken references and invalid scenario claims.

Run in `devenv shell`:

```sh
elixir scripts/check_hldd.exs
elixir scripts/hldd_options.exs --check
elixir scripts/hldd_coverage.exs --check
elixir scripts/hldd_views.exs --check
nix build .#checks.x86_64-linux.hldd
```

Run Marshall's `mix precommit` for web or shared governance changes and the
appropriate component/native checks. Use the architecture and code-contracts
workflows required by root guidance. Report changed chapters, scenario/security
gaps, exact checks and execution scope in the change summary. Keep the skill,
checker and handbook aligned when this maintenance contract changes.
