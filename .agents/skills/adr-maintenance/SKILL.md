---
name: adr-maintenance
description: Create, update and supersede Overalls architecture decision records and reconcile implementation evidence with code. Use when architectural decisions change, a review finds design drift, implementation status changes, or the user asks to maintain ADRs, their index or architecture overview.
---

# ADR maintenance

1. Locate the repository root with `git rev-parse --show-toplevel`. Read root
   `AGENTS.md`, `docs/architecture/decisions/README.md`, relevant records and the
   actual changed code/configuration/tests. Read the review if one triggered this
   work. Separate observations, assumptions and unresolved choices.
2. Choose the smallest accurate update:
   - Existing decision still holds: update facts, implementation evidence, open
     questions and implementation status in place.
   - New decision: copy `docs/architecture/decisions/template.md`, allocate the
     next unused ID, and fill every section with concrete rationale.
   - Material replacement of an accepted decision: create a new record. Preserve
     the old rationale. Once the replacement is accepted, set the old status to
     `superseded` and update both `Supersedes` and `Superseded by`. Keep history and
     historical implementation evidence. Before acceptance, describe the intended
     replacement through Related decisions without activating supersession.
3. Use decision status `proposed`, `accepted`, `rejected` or `superseded` separately
   from implementation `planned`, `partial` or `implemented`. Existing explicit
   task/plan authorization can establish acceptance; do not request it again.
   Unresolved new choices stay proposed. Describe why alternatives were rejected
   and which properties verification must establish.
4. Link concrete implementation artifacts for partial/implemented claims and
   explain what each proves. Installed libraries, an accepted ADR or a planned
   test do not prove operational behavior. Mark remaining obligations explicitly;
   never mark a feature implemented merely to satisfy the checker.
5. Update the decision index in the same change, and the architecture overview
   when boundaries or the current implementation map change. Add reciprocal
   supersession references and related links. Use the documented simple metadata
   and relative inline Markdown link syntax; avoid introducing a second template.
6. Run `elixir scripts/check_adrs.exs` from the root (or
   `elixir ../scripts/check_adrs.exs` from Marshall), then the component's required
   checks. Read failures and fix the actual records; do not weaken validation to
   conceal missing evidence or contradictions. The checker is structural only.
7. Summarize affected IDs, decision/implementation status changes, authorization
   used, checks performed and any remaining questions. Use `$architecture-review`
   when the change needs a substantive review.
