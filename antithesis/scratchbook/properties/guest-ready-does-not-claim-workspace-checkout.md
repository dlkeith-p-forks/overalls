# guest-ready-does-not-claim-workspace-checkout

P1; high confidence; safety/reachability. Proposed `Always` message **"Guest readiness does not claim repository checkout completed"** compares guest checkout completion to its durable `done` marker and actual selected Git HEAD, while VM running/ready may coexist with waiting, retrying or failed checkout. The current launch page's `:complete` means VM admission and navigation, with text saying the clone occurs after boot; it is not a checkout-complete claim. Proposed `Sometimes(condition)` message **"Guest remained ready while workspace checkout was pending"** requires this meaningful independent-state case. Both are **missing** per [fresh scan](../existing-assertions.md).

Source: `nix/domains/artifacts/guest/private-services.nix:57-73` keeps workspace service outside required readiness units; Git provider availability must not gate VM readiness. `lilly/lib/lilly/vm/executor.ex:467-495` returns the running observation unchanged after asynchronous source handoff. `lilly/lib/lilly/vm/workspace_source.ex:46-66` starts one supervised delivery task without linking it to the executor. `lilly/lib/lilly/vm/driver.ex:746-764,893-919` tracks source delivery separately. In guest code, `lyra/src/workspace_receiver.rs:570-635` persists source once, permits retry before done, and writes `done` only after checkout rename/sync. `lyra/src/workspace_checkout.rs:36-130` resolves named refs later than Marshall's browser visit. ADR-0128/0157 describe distinct readiness and workspace states.

History: admit one browser source visit and boot the real guest while controlled Git origin stays unavailable or changes a branch. Establish guest readiness/SSH independently, then allow workspace attempts, interrupts around rename/done and eventual origin healing. Repeat source delivery and guest service restart. The same VM stays running, but any checkout-complete display/response must wait for durable done plus actual Git tree. The selected commit may differ between independent visits; do not assert that canonical URL pins HEAD.

Independent oracle: use guest readiness channel and native VMM identity for ready, guest workspace journal/source/done marker and `git rev-parse HEAD` plus a controlled origin invocation log for checkout. Check the actual product status surface if a complete signal exists. A Lilly accepted source-delivery receipt alone proves only delivery, not clone success. If no product surface claims checkout complete, scope `Always` to internal completion markers and retain the reachability assertion.

SUT guidance: proposed `Reachable` **"Guest ready before repository checkout completed"** at the readiness/source split can guide the case, while the workload `Always` checks any completion claim against actual guest content. `Sometimes(condition)` captures the allowed state instead of misclassifying slow Git as a VM readiness defect.

Values: source absent/default/ref/change; Git origin available/unavailable/flapping; branch unchanged/moved; delivery before/after readiness; crash before rename/after rename/before done/after done; one/two actor or guest service restarts; retry budget 0/1/max configured. Native TCG guest and controlled Git origin are needed for readiness/content; service-only state models cannot establish guest checkout.

Open questions: None for the current launch surface; a future checkout-complete product signal would need a fresh audit.

### Investigation Log

#### Which current user-facing API or page labels checkout complete?

- Examined: `marshall/lib/marshall_web/live/launch_live.ex:20-71,157-193`, `marshall/assets/js/repository_launch.js:90-115`, `nix/verification/tests/machines/repository-launch/browser.py:59-75`, `nix/verification/tests/machines/repository-launch/guest.exs:35-57`, and `lilly/lib/lilly/vm/executor.ex:467-495`.
- Found: `LaunchLive` marks `:complete` after `Compute.provision` returns, issues an admission receipt and says the new VM will clone when it boots; the browser then navigates to the machine. The native guest probe separately waits for guest `done` and checks actual HEAD. Lilly starts source delivery after running observation and does not make it a readiness gate.
- Not found: a current page or API in the inspected launch path that asserts checkout completion based on VM readiness or source delivery.
- Conclusion: resolved for this path. Scope the property to independent guest ready/done/HEAD states; do not treat the admission receipt as a checkout receipt.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: guest boot/source/HEAD/done marker and independent Git or file bytes; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
