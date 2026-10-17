# Agent context, planning and guest guidance review

## Scope and authority

The user's October 16, 2026 approved implementation plan authorizes durable
context compaction, Plan/Work collaboration, composer commands, guest project
instructions, skill discovery and manager-controlled public skill installation.
The implementation worktree starts at `95f7662f5`. ADR-0178 and ADR-0179 record
new accepted behavior; they preserve ADR-0100's Marshall ownership and
no-automatic-replay rule, ADR-0175's current ACL boundary and ADR-0158's durable
guest identity.

This review covers the implementation source and focused execution evidence.
It does not claim native fleet, physical isolation, production provider, or
browser deployment acceptance.

## Required boundaries

| Boundary | Required result |
| --- | --- |
| Domain ownership | Agents owns active context and checkpoints separately from transcript events; Threads remains task and sharing authority. Managed skill versions and immutable operation receipts are durable Ash resources. |
| Context coverage | Turn eligibility and the active event frontier exclude later queued prompts and preserve each continuation exactly once; tool-call/result groups stay complete. |
| Mode and instruction trust | Plan/Work is persisted application state. Repository guidance, skills and generated summaries cannot change authority or trusted mode. Plan is instructional, not a read-only sandbox. |
| Provider effects | Existing Ziggy pull, current inference admission and accounting apply. Compaction has a distinct work purpose. Claimed ambiguous effects remain uncertain without automatic replay. |
| Guest boundary | Discovery and installation use current authenticated executor binding on Linux and Windows. Marshall's host filesystem is not thread context. |
| Sharing | Current write authority gates prompts, questions and plan implementation; management authority gates skill installation/configuration. Stale controls cannot authorize an operation. |
| Recovery | Immutable snapshots and accepted answers survive restart. Installation ambiguity reconciles status; reopen restores a pinned skill commit and digest. |
| Data custody | Prompts, file content, summaries, skill bodies and provider payloads stay out of diagnostics and accounting. New durable resources enter the retention inventory. |
| Deployment | No new listener or service. Compatible consumers and executors precede feature enablement; incompatible guests refuse explicitly. |

## Findings and disposition

No final production-source findings are recorded yet. Initial inspection confirms
that selecting a bounded recent event window is not compaction and cannot
establish covered-history identity. ADR-0178 replaces that implementation choice
with an explicit checkpoint boundary without changing retained transcript
ownership.

The existing `thread_grants_versions` retention inventory omission is corrected
in [ExpireLifecycleEvents](../../../marshall/lib/marshall/compute/expire_lifecycle_events.ex).
This restores ADR-0149/0175's existing retention inventory contract: the worker's
ninety-day version policy and global 1,000-row sweep remain unchanged. It adds no
new authority or lifecycle decision.

## Verification record

The retention correction passed **7 focused checks: 6 tests and 1 property** on
2026-10-16 with seed `332929`, maximum two cases and 0.9 seconds test runtime.
The executed files were
[PaperTrail policy tests](../../../marshall/test/marshall/paper_trail_policy_test.exs)
and [lifecycle audit tests](../../../marshall/test/marshall/compute/lifecycle_audit_test.exs).
The run used an isolated database/cache while other feature files were being
added; it emitted incomplete-resource compilation warnings. It is neither a
warnings-as-errors pass nor a frozen pristine-baseline result. The captured log
is `/tmp/agent-context-baseline.log`; no guest, provider or deployment acceptance
follows from this bounded retention result.

The Ziggy transport subset passed **30 checks: 22 tests and 8 properties**, in
4.9 seconds with warnings-as-errors on 2026-10-16. The source-level fixture uses
actual local HTTP provider and control endpoints; it verifies Responses routing,
compaction state preservation, Responses accounting classification, closed
context/native-support/incomplete/cancelled errors, the 1 MiB response cap and
delivery retry/loss without provider replay. Failure usage retains provided
fields while absent usage remains unknown. The captured result is
`/tmp/kittens-agent-context-ziggy-focused.log`. This is local transport evidence,
not native guest, physical fleet or live provider acceptance.

Guest Windows library, agent executor and SSH roster cross-target compilation
passed with the pinned Rust 1.97.1 toolchain after adding native SID-profile
lookup and missing-profile activation. This establishes cross-target types and
compilation only; no Windows runtime, profile/ACL or power-loss result follows.

The focused Marshall feature suite passed **64 cases (61 tests and 3
properties)** with the generated schema installed. It covers context and
compaction policy, summary/native response validation, checkpoint installation,
durable planning questions and proposals, same-machine implementation, thread
controls and managed skill lifecycle. Existing agent, thread and lifecycle
regressions passed **55 cases (53 tests and 2 properties)**. The focused Ziggy
suite passed **24 cases (18 tests and 6 properties)**, and the Lyra unit suite
passed **58 tests**. The unrestricted Marshall suite was started but stopped
after more than fourteen minutes without producing a completion result; it is
not represented as a passing gate.

Required evidence includes state/SQL properties, bounded instruction and skill
parser cases, native Linux and Windows discovery, browser keyboard/mobile
commands and the full Marshall-to-Ziggy-to-provider-fixture-to-guest loop.
Provider-native compaction needs separate verified capability evidence before
enablement. Native guest execution, physical isolation, independent-host
recovery and production provider behavior cannot be inferred from unit or
synthetic browser tests.

## Remaining work

The remaining acceptance work is native Linux/Windows guest execution, browser
keyboard/mobile probes, independent-host recovery, and provider-native
capability evidence. The source review found no unresolved ownership, lock,
generation, retention or redaction issue in the focused scope. Keep ADR status
partial until the native and deployment evidence exists.
