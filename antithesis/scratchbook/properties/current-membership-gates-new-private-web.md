# current-membership-gates-new-private-web

Priority: P0. Confidence: high in the intended contract and testability; no new hosted run. Type: safety, with an authorized progress witness.

## Guarantee and proposed assertions

For a private, sharing-capable VM, a recipient's newly admitted web request may reach the guest only if that recipient has current persisted Cedar web authority at the admission transaction. Once a role removal commits before admission, the recipient's prior cookie and historical grant must not deliver a fresh request nonce to the guest. An admission that acquired the VM lock before the removal can complete; order by the VM lock/transaction, not client-send or response time. Proposed `Always(no_post_revocation_private_web_effect, "Revoked membership cannot deliver a newly admitted private web request to the guest")`. Proposed `Sometimes(authorized_private_web_nonce_observed, "A current private web member reaches the guest after access changes")` requires a real authorized positive case in the same scenario. Both are missing according to `../existing-assertions.md`; ordinary tests are not SDK assertions. `Sometimes` has a semantic condition, not a constant true value.

## Source and decision trail

- `marshall/lib/marshall/access/CONTRACTS:1-9` claims current, unarchived Cedar grants and rejects historical grants or cached browser roles. `marshall/lib/marshall/access/authorization.ex:25-59` builds the entity from persisted Grant and team membership for each decision; `:77-86` locks VM for live operations.
- `marshall/lib/marshall/access/sharing.ex:11-24,54-116` changes grants under the locked VM, archives the prior grant, and retains immutable idempotency results. Replaying an old change receipt is not a new grant.
- `marshall/lib/marshall/ingress/web_streams.ex:31-54,113-136,163-195` performs new and renewal admission, rereads the stored login and calls current `Authorization.require!`. `marshall/lib/marshall/ingress/execution.ex:14-53` independently checks current host/VM execution under locks.
- `audi/lib/audi/http/proxy.ex:23-40,61-79,88-140` requires a control grant before guest connection and forwards bytes only after connector opening. ADR-0077 (`docs/architecture/decisions/0077-teams-and-shared-resources.md:25-29`) also claims per-decision persisted team membership; this candidate can include that as a value, but an ordinary per-VM grant is the first proof target.

The contracts and ADR are requirements to test, not evidence that every interleaving already holds. No validated incident or current SUT defect is asserted.

## Fault history, independent effect and progress witness

With real Marshall/PostgreSQL, Audi and a guest HTTP echo endpoint on an owned synthetic VM, grant recipient R web access, establish a stored login/cookie and prove a unique request nonce reaches the guest recorder. Concurrently run an owner-authorized role revocation and R's new private request, including lost HTTP or Control replies and a Marshall/Audi restart. Read the committed Grant/Change rows to order the fence, then reconcile the guest recorder's *new* nonce. A 403, timeout or missing diagnostic cannot prove no effect. Issue an owner or freshly regranted recipient request after recovery and require its distinct nonce in the guest; this checks useful progress and recorder health. Do not treat a request admitted before the revocation lock as a violation.

Value menu: `:web` grant versus revoked; same-key old sharing retry versus new-key regrant; direct grant versus team membership removal; private endpoint only; Control reply delivered/lost; revocation before/after web admission lock; service process loss before/after commit. Keep cookie and guest payload out of assertion metadata. Add a branch/replay checkpoint at `WebStreams.perform(:open)` after `identity!/5` and before `create_stream!/9`, with fixed IDs/status only; a guest recorder nonce is the independent effect oracle. Hosted real services plus TCG guest or a real guest app is needed for full byte-effect scope. A mock Control response alone cannot prove this property.

## Open Questions

- How will the replacement harness add a bounded per-request nonce ledger to the existing private-web guest origin and browser journey? `(partial: the native fixture covers real login and Audi routing, but its guest observer currently records only aggregate counters)`

### Investigation Log

#### Which minimal private guest app and browser-login fixture can issue and record unique non-sensitive request nonces through the full Audi route?

- Examined: `nix/verification/tests/machines/private-web/guest.py:1-106`, `browser.py:48-112`, `driver.py:42-140`, and `nix/verification/tests/machines/sharing-surfaces/browser.py:150-190`.
- Found: the disposable Python guest origin serves HTTP, streaming HTTP and WebSocket on ports 8080/3000; the Playwright journey signs in over HTTPS, obtains the host-only Audi cookie, keeps original streams open across team removal, then makes a fresh request. The driver reads guest counters through owner-authorized SSH. Reuse this owned fixture shape and extend its guest observer with a bounded ledger of synthetic nonce IDs, without recording cookies, headers or request bodies.
- Not found: per-request nonce capture in the current origin or an assembled replacement harness.
- Conclusion: the concrete fixture is identified; byte-effect attribution after the admission lock remains a targeted harness addition. Counter increments alone cannot classify one racing request.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: post-fence guest nonce and current authority/lease/boot ledger; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
