---
sut_path: /home/ghuntley/src/kittens-antithesis-reset
commit: c835eb1017d24a001215c319373fa4204d64269b
updated: 2026-10-13
external_references: []
scope_answer: "Repository only (Recommended)"
focus: "06 — Security Boundaries"
status: "source-grounded candidate discovery; no hosted run"
---

# Property discovery focus 06: security boundaries

The fresh [SUT analysis](../sut-analysis.md), [existing assertion scan](../existing-assertions.md), [briefing](property-briefing.md) and Antithesis property references were read first. Every proposed Antithesis assertion below is missing. These are accepted contracts and decision claims to test, not verified guarantees or allegations of a current defect. Each negative case uses an independent guest effect witness, and each scenario includes a current-authority progress case. A refusal, timeout, diagnostic or suite exit alone is never the safety oracle.

| Canonical candidate and evidence | Priority / confidence | Type and specific property | Assertion and Antithesis angle | Open questions |
| --- | --- | --- | --- | --- |
| [current-membership-gates-new-private-web](property-candidates-06/current-membership-gates-new-private-web.md) | P0 / high | Safety: a private request newly admitted after role revocation commits cannot reach the guest using a historical grant/cookie. | `Always` on committed revocation order plus guest nonce; `Sometimes(authorized_private_web_nonce_observed)` requires current-member progress. Race VM lock, membership replacement, stale cookie and lost replies. | Which minimal guest app and browser-login fixture gives a full Audi private route and independent nonce recorder? |
| [expired-web-lease-stops-existing-guest-bytes](property-candidates-06/expired-web-lease-stops-existing-guest-bytes.md) | P0 / high contract, medium composition | Safety: old Audi web/editor stream cannot deliver a new guest nonce after the last valid local grant deadline. | `Always` on post-deadline guest effect; `Sometimes(current_lease_resumed_guest_bytes)` confirms a new authorized stream after recovery. Block renewals, lose hints and suspend guard/worker. | How will a hosted guest fixture mark post-deadline ordering without synchronized clocks? Which hosted fault controller can suspend the guard while retaining production ownership? |
| [stale-local-execution-cannot-forward-guest-bytes](property-candidates-06/stale-local-execution-cannot-forward-guest-bytes.md) | P0 / high contract, medium composition | Safety: a retired placement/epoch stream cannot send a new nonce to its old physical guest after Lilly withdraws local authority and the old guardian ends. | `Always` on old-boot recorder after guardian-death barrier; `Sometimes(current_execution_nonce_observed)` requires new-boot progress. Race stop/start or stopped relocation with View, guardian and connector traffic. | How can the harness independently observe old guardian death? `(partial: local view and guardian path traced)` Can TCG retain two distinguishable boot recorders? |
| [guest-identity-never-transfers-on-email-reuse](property-candidates-06/guest-identity-never-transfers-on-email-reuse.md) | P0 / high persistent rule, medium physical scope | Safety: retirement permanently reserves old GuestAccount UUID/UID/home and a fresh same-email User cannot use the old guest identity; active same-user email edits preserve it. | `Always` on persisted identities plus guest home owner/read effects; two `Sometimes` conditions require same-user continuity and distinct-home replacement progress. Race retirement, same-email registration, admission and lost replies. | Which guest fixture covers SSH, browser terminal and editor on one retained identity across both guest families, versus capability-specific cases? |

## Breadth, evidence and limits

Inspected current access/Cedar entity construction, transactional role replacement, web admission/renewal, Audi local lease/guard and byte relay, Lilly authenticated local ingress/guardian and private subscription, guest-account allocation and retirement, editor account/execution binding, ADR-0052/0077/0142/0153/0158 and the retained native account-lifecycle fixture. The evidence files give exact source lines, fault histories, value menus, branch checkpoints and independent oracles. Existing ordinary unit/property/native tests are leads and scoped historical evidence; they are not Antithesis assertions, fresh hosted results, or proof of Firecracker isolation. Full byte-effect checks require real Marshall/PostgreSQL, Audi, Lilly and a real guest recorder. TCG can establish software-emulated guest behavior; Firecracker jail/cgroup and native relocation remain separate machine claims. Historical restore and old-disk conversion are excluded by ADR-0158.

## Architecture and handbook impact

This discovery changes only scratchbook research. It does not change behavior, configuration, protocol, operations, acceptance evidence, an accepted decision or an HLDD-covered interface. Architecture impact is none at this stage; affected claims are ADR-0052, ADR-0077, ADR-0142, ADR-0153 and ADR-0158. No HLDD update or governance receipt refresh is warranted for prospective candidates. A later harness or production change must reassess architecture/HLDD impact against its own final diff.
