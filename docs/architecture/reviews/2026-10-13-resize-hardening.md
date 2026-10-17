# Resize hardening review — 2026-10-13

## Scope and authority

Part of the authorized 2026-10-13 investigation of refused clones, relocations
and resizes (host shell, database reads, Porsche machine creation and
deletion, changes without limit). [ADR-0166](../decisions/0166-resize-hardening.md)
records the decision; this review records the evidence and verification.

## Production findings

| Observation | Evidence |
| --- | --- |
| Every resize of the previous fourteen days completed (five requests, 12 to 40 seconds, including two on the clone copy `5cc1e9f9` minutes after it was published) | `compute_resize_requests` |
| The owner's "error, retry" and "stuck" reports traced to clone and relocation refusals, not resize ([clone review](2026-10-13-clone-cleanup-liveness.md)) | journals, database |
| Resize had no scriptable entry point, refusals reached the owner as a generic flash without an event, a stop confirmed without its disk was an invalid outcome that rolled back the host exchange, and a request could not be withdrawn before any size applied | `resize.ex`, `resize_live.ex`, `ssh_command.ex` at `24bc653b9` |

## Architecture assessment

Initial and final assessments: the change extends the Porsche command catalog
(one physical command), the SSH receipt resource (a resize request reference),
the resize request state machine (cancelling and cancelled phases, a
cancellation timestamp) and the coordinator's outcome handling (the diskless
stop clause and the cancel paths). Authorization is delegated to the existing
`resize`, `retry_resize` and new `cancel_resize` domain actions under manage;
capacity holds are restored by cancellation and never released while a
running machine needs them; no physical effect is added. ADR-0051's
out-of-scope clause is superseded with a reciprocal note; ADR-0053's disk
limit is enforced unchanged by the command's option validation.

## Verification

| Gate | Result |
| --- | --- |
| `resize_cancellation_test.exs` (running cancel through unchanged restart; stopped cancel on the stop receipt; refusals once resizing and when fenced; diskless stop recorded then retried) | pass |
| `commands_test.exs` resize (accept, replay, empty refusal, in-progress refusal, cancel receipt) | pass |
| `resize_live_test.exs` page cancel (control only while stopping, cancelling stages, form returns with original sizes, refused after sizes apply) | pass |
| `ssh_command_test.exs` resize parse and option limits | pass |
| `resize_history_test.exs`, `resize_test.exs` | pass (2 properties, 17 tests) |
| Marshall `mix logging.check`, `mix contracts.check`; protocol contracts | pass |
| Protocol, Marshall, Porsche and Lilly `mix precommit` on the merged tree | protocol 256 tests (98 properties), Porsche 95 (16), Marshall 1474 (239), Dialyzer 0 in each; Lilly 539/540 with `ingress_execution_test.exs:201` (actor death revokes authority) failing under the parallel gate load and passing three times in isolation; the branch has no Lilly change and the same Lilly tree passed on main (`31b56c321`) |
| Porsche journey on overalls at `cda064f36` (`new` → `resize --cpu 2` → `request show` → `request cancel` → `resize` again → `clone` → `rm` ×2) | `new` ran in 33 s; an option-less `resize` was refused `invalid_vm_size`; `resize --cpu 2` was accepted in `stopping`, had reached `resizing` two seconds later, so `request cancel` was refused (`resize_not_cancellable`, no receipt) and the request completed (generation 4, 2 CPU); a second identical `resize` was refused as no change; the same-host `clone` of the running source completed with its prune confirmed 16 s after submission; both machines deleted. The pre-mutation cancel window was shorter than a client round trip on this host, so cancellation is accepted on the unit, page and SSH tests only |
| `vm.resize_refused` from Porsche | not emitted for gateway requests: the gateway runs the action inside its own transaction, the coordinator's rollback propagates to it, and the gateway logs the closed reason as `api.request_unauthorized`; `vm.resize_refused` covers the page and direct domain callers |

## Limits and follow-up

- A resize fenced by `physical_state_unconfirmed` stays retry-only even after
  a later outcome confirms the stop (ADR-0166 open question).
- The native browser resize journey (`resize-browser`) was not rerun here; the
  page change is covered by the LiveView test.
