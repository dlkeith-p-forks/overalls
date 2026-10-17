# lilly-view-restart-withdraws-stream-authority

P0; medium confidence; safety. Planned `AlwaysOrUnreachable` message: **"Lilly View restart withdraws stale stream authority before forwarding"**. If the production View process restarts while a stream is active, no post-restart guest bytes or privileged forwarding may use a pre-restart proof until Runtime, actor and dependent connector have republished current authority. The optional View-failure path may be absent in an ordinary run, so `AlwaysOrUnreachable` is appropriate when that path is observed. The [fresh assertion scan](../existing-assertions.md) finds the assertion **missing**.

Source: `lilly/lib/lilly/application.ex:45-57` places `Lilly.Execution` before Runtime and connectors in a `:rest_for_one` tree. `protocol/lib/overalls_protocol/view.ex:1-18,45-68` owns volatile protected ETS rows, subscriptions and writer-lifetime removal. `lilly/lib/lilly/execution.ex:106-117` joins runtime, durable intent, live actor row and expiry through separate reads; these are not one atomic snapshot. A standalone View restart with retained subscribers would invent a topology the real root supervisor tears down. Stale lookup alone is a hypothesis, not evidence of stale downstream effects.

Workload and independent oracle: establish an authorized stream through actual Audi/Lilly connectors, keep a controlled guest byte source, kill the production Execution child under its real supervisor and race stream traffic/replacement command. Workload records bytes accepted after restart and current Store command; watch actual connector process identities and authority/stream closure. Do not use a direct test View with subscribers left alive as the safety oracle. An optional `Reachable` message **"Production View restart closed dependent stream connector"** records the meaningful restart consequence.

Value menu: zero/one/many streams; runtime connected/disconnected; replacement intent before/during/after View failure; live/boot rows; subscription timing; old actor alive/dead. Hosted real BEAM releases and Unix connector can exercise supervision; native guest socket custody needs machine testing. Open questions: None.

Answer: Use the production Lilly.Ingress.Server socket path to send a tagged guest byte before/after killing the Execution child, and record socket/guardian/connector PIDs with Runtime and command identity. The root rest_for_one tree places Execution before Runtime and ingress. Ingress.Server.terminate closes the listener and kills linked workers; its guardian separately monitors the stream owner and actor. A stand-alone View test with surviving subscribers would observe a topology that production does not run.

### Investigation Log

#### Which forwarding seam provides a post-restart byte witness synchronized with connector and command identity?

- Examined: `lilly/lib/lilly/application.ex:45-72; lilly/lib/lilly/ingress/server.ex:88-129,182-252; lilly/lib/lilly/ingress/backend.ex:5-35; lilly/lib/lilly/execution.ex:106-117`.
- Found: Use the production Lilly.Ingress.Server socket path to send a tagged guest byte before/after killing the Execution child, and record socket/guardian/connector PIDs with Runtime and command identity. The root rest_for_one tree places Execution before Runtime and ingress. Ingress.Server.terminate closes the listener and kills linked workers; its guardian separately monitors the stream owner and actor. A stand-alone View test with surviving subscribers would observe a topology that production does not run.
- Not established: No current hosted/native execution was run in this investigation; source and test presence alone do not establish the physical outcome.
- Conclusion: resolved; Remove forwarding-seam question; prescribe production ingress byte witness and real rest_for_one restart.

## Evaluation and proof boundary

**Proof boundary:** Draft selection: `integrated-zfs-guest`. proposed-real-inner-zfs-backed-lilly-plus-tcg-guest; unbuilt, no Firecracker proof; independent witness: retained QEMU PID/boot challenge/overlay plus independent guest or connector effect; current measured ZFS pool required for accepted placement. Native companion: required. Current state: unexercised; no hosted catalog-property evaluation or baseline exists.

**Evaluation follow-up:** `R2`: The focused command must also emit a distinct `Reachable` at the actual incompatible/corrupt/restart/negative-status danger branch. Optional-path safety can pass without that branch; positive compatible traffic is insufficient. Record exact selected image/profile, guest family, source provider/revision, drive count and enabled capability as applicable; unselected variants are unexercised.
