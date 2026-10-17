# source-v2-delivery-envelope-v1-boot-bound

P1; medium-high confidence; safety and progress reach. Planned `Always` message: **"Workspace source-v2 delivery accepts only matching v1 boot envelope"**. A `delivered` journal for a source-v2 reference is permitted only after a delivery-envelope-v1 reply that echoes exact placement, execution epoch, boot challenge and fresh nonce while the same physical boot still holds authority. A wrong version, stale boot or changed source digest must not become delivered. The [fresh assertion scan](../existing-assertions.md) finds this SDK assertion **missing**. `Always` applies to every settled delivery journal; `Reachable` **"Workspace source-v2 delivery accepted current boot without delaying readiness"** marks actual guest acceptance and independently observed VM running readiness.

Source: `lilly/lib/lilly/vm/workspace_source.ex:86-126,181-223,226-272` fences each attempt and requires a closed **v1 delivery envelope** containing a nested source-v2 document, then correlates the reply and nonce. `:276-288` journals a digest incorporating source-v2 fields; `:46-67` dispatches delivery under independent supervision. `lilly/lib/lilly/vm/executor.ex:468-495` starts delivery after running observation; `protocol/lib/overalls_protocol/readiness.ex:19-60` separately validates boot-readiness v1. Source2, delivery-envelope1 and readiness1 are separate layers; a failed source clone is not evidence of failed VM boot.

Workload and independent oracle: boot a source-capable guest, observe its readiness receipt and physical boot ID, then delay/duplicate/change delivery responses across a reboot or newer generation. Compare guest checkout/done markers and nonce receipt to Lilly's boot-bound `workspace-source.json` state; independently confirm the VM remains running when source delivery fails. Do not treat an unconfirmed socket reply as accepted. SUT `Reachable` **"Workspace delivery rejected stale v1 envelope after boot replacement"** identifies the rare fenced branch.

Value menu: nested source v2 versus 1/3; delivery envelope 0/1/2; matching/stale placement, epoch, challenge or nonce; same/different source digest; response lost/duplicate; reboot before/after guest acceptance; guest source fetch success/failure. Hosted software-emulated guest with actual vsock and source service can establish guest-level delivery; a stub guest checks only host correlation. Native Firecracker remains needed for jail/socket custody. Open question: where can a narrowly scoped byte mutator between the actual Lilly vsock connector and Lyra guest responder alter one reply field without replacing either endpoint? `(partial: both endpoints validate the v1 envelope; a composed TCG transport seam is not present)`

### Investigation Log

#### Where can a controlled responder inject a wrong envelope while retaining the actual vsock and boot path?

- Examined: `lilly/lib/lilly/vm/workspace_source.ex:68-126,181-272`, `lyra/src/workspace_receiver.rs:56-135,146-175`, and the `guest-vmm` topology in `../deployment-topology.md`.
- Found: Lilly connects through the jailed `v.sock` to guest port 1031, sends a v1 envelope with a nested validated source-v2 document, and correlates the v1 response to placement, epoch, challenge and fresh nonce. Lyra derives its binding from the real kernel command line and rejects wrong incoming envelope fields. A negative *reply* case needs an in-path, one-shot reply-field mutation after the real guest responds, or a controlled test guest responder attached to the real broker; the former retains more of the production path.
- Not found: an existing byte mutation seam in the actual QEMU/vsock broker or an assembled hosted guest responder. Directly calling `reply/3` or replacing the broker would cover only a narrower validator.
- Conclusion: partial harness design. Positive acceptance must still use the unmodified real Lyra receiver and physical boot witness; negative transport mutation has a separately labeled scope.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: guest boot/source/HEAD/done marker and independent Git or file bytes; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
