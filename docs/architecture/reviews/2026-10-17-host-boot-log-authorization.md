# Host boot-log authorization review (2026-10-17)

## Scope and architecture impact

This review covers the read-only host serial log returned by Marshall's
`Terminal.Authority`, Lilly's authenticated terminal stream, VM actor and
executor. A guest that cannot complete bootstrap still needs diagnostics.
Reading that host file must not require a functioning guest terminal daemon
or advertise a terminal capability that the image does not implement.

This is an authorization and execution-fencing correction under
[ADR-0083](../decisions/0083-terminal-host-stream-and-registry.md), whose
existing `boot_log` controls read bounded host diagnostics.
[ADR-0082](../decisions/0082-guest-terminal-multiplexer.md) continues to govern
interactive guest sessions. [ADR-0190](../decisions/0190-native-kernel-provenance-and-admission.md)
keeps unqualified native capabilities disabled and qualifies only the separately
reviewed exact FreeBSD image. This diagnostic change adds no
wire schema, guest endpoint, domain, deployment role or guest capability.

## Findings and required boundaries

### Host diagnostics incorrectly inherited guest terminal admission

The earlier Marshall path applied the image's `terminal` capability before
requesting the boot log. Lilly then obtained the path through
`Actor.terminal_identity/2` and `Executor.terminal_options/2`, which require a
running outcome, guest terminal capability and a running VMM observation.
That couples the diagnostic needed to investigate an incomplete boot to the
guest service whose failure is being investigated.

The authorized correction gives the host log its own read path. Marshall must
still check current Cedar VM read authority, an undeleted VM, its unique current
runnable placement and epoch, and a fresh authenticated host report advertising
stream protocol 2. Lilly must accept the request only from the actor's assigned
stream PID and for the newest stored runnable command. Persisted boot and intent
must match that command's VM, placement, execution epoch and generation. A newer
stop, delete or replacement command, stale or foreign request, missing identity
or ambiguous placement must refuse.

The read returns at most 16 KiB of host-captured bytes and a cursor. It must not
dial the guest, start a guest manager, return the boot challenge or jailed vsock
path, grant terminal input, or report guest readiness. Console bytes remain out
of diagnostic events, audit rows and database payloads. Existing private file
custody and retention remain separate obligations under
[ADR-0182](../decisions/0182-unprivileged-lilly-beam.md) and
[ADR-0154](../decisions/0154-guest-boot-profile.md).

### Native image identity remains an independent cause of bootstrap failure

A deployed stock FreeBSD image and a source-built candidate have different
kernel and agent closures. A historical capability row or a host-log read
cannot add AF_VSOCK, install missing daemons or turn the stock image into the
reviewed custom candidate. Native runtime records remain bound to the exact
images in the [native kernel review](2026-10-17-native-kernel-attestation.md).
No image rollout or capability enablement follows from this diagnostic fix.
An authorized read also cannot guarantee useful serial output: an empty or
sparse retained file does not identify the failed guest stage or prove that
the guest reached a login prompt.

## Validation and remaining gaps

The implementing source is
[Marshall authority](../../../marshall/lib/marshall/terminal/authority.ex),
[Lilly stream](../../../lilly/lib/lilly/terminal/stream.ex),
[VM actor](../../../lilly/lib/lilly/vm/actor.ex),
[executor](../../../lilly/lib/lilly/vm/executor.ex) and
[bounded host reader](../../../lilly/lib/lilly/vm/boot_log.ex). Independent
control-flow review found no remaining source blocker after the incarnation
correction below. The focused Lilly suite passed 55 checks (13 properties and
42 tests) in 16.7 seconds; its execution record is
`/tmp/overalls-boot-log-lilly-focused.log`. This includes the
[reader fixtures and generated histories](../../../lilly/test/vm/boot_log_reader_test.exs),
[actor fences](../../../lilly/test/vm/actor_test.exs), original writer,
terminal and readiness suites. Coverage includes
pending and failed runnable-command outcomes with the guest terminal capability
disabled; Cedar, host freshness and current-placement refusal; assigned stream
ownership; stale command, epoch and generation refusal; matching persisted boot
and intent; bounded cursor reads; and absence of guest dialing or returned guest
credentials. Unit and local stream fixtures cannot establish production browser
delivery, deployed image correction or native guest acceptance.

The independent source review identified and corrected a boot-log incarnation race:
launch published the new persisted boot identity before removing the previous
boot's log. Checking boot/intent identity around a read alone therefore cannot
prove the file belongs to that boot. The new reader also requires the exact
unchanged `launch-attempt.bin` witness, which launch publishes after retiring
the old log. A strictly older attempt from the same placement and epoch is
accepted only for a still-running adopted generation, with the full confined
VMM observation before and after the read. Failed adopted-generation logs stay
unavailable. Boot, intent, attempt and private inode/custody are rechecked after
the final observation, and the actor rechecks the newest stored command around
all reader I/O. The reader returns only bytes/cursor, without borrowing the
running-boot authority of the guest terminal endpoint or changing launch order.

The focused Marshall authority, LiveView and navigation suite passed 27 tests
in 16.7 seconds, recorded at
`/tmp/overalls-native-boot-log-browser-fixture.log`. Its synthetic native-image
fixture seeds the catalog row after placing an ordinary test guest; it does not
provision or admit a native image. The
[authority tests](../../../marshall/test/marshall/terminal/authority_test.exs),
[diagnostic LiveView test](../../../marshall/test/marshall_web/terminal_live_test.exs)
and [navigation test](../../../marshall/test/marshall_web/editor_workspace_test.exs)
cover refusal boundaries, zero automatically opened registry rows across refresh
and the bounded host response. Structural Monospace, workspace TypeScript and
terminal JavaScript checks passed at
`/tmp/overalls-native-boot-log-ui-focused.log`; all-file Python formatter, Ruff
and ty checks passed at `/tmp/overalls-native-boot-log-python.log`.

The machine navigation offers a distinct `Boot log` link to
`/machines/:id/terminals?view=boot-log`. Diagnostic mode selects the existing
read-only serial pane without listing guest sessions or automatically opening
a guest terminal. This makes the retained host diagnostics reachable for a
pending or failed guest whose terminal capability is disabled. These local
checks do not establish a complete NixOS journey through a pending or failed
guest, production activation
or native-image acceptance.

The final presentation uses a typed
[single-flight poller](../../../marshall/assets/js/terminals/boot_log.js) and a
correlated LiveView callback. Only the selected, connected view in a visible
document polls. EOF and temporary refusals wait two seconds, while pause or
disconnect invalidates pending replies; an active emulator write finishes before
the next request. Destruction removes the timer and visibility listener.
Rendering validates a safe cursor, at most 16 KiB of decoded bytes and an exact
byte-length cursor advance; rewind resets and refetches zero. These controls
bound browser work and preserve host authority. The responsive navigation uses
natural row height and existing grid tokens without new colours, resources or
interactive guest authority. Node tests passed 31 checks and strict TypeScript
passed. The later complete Marshall gate below records the final JavaScript,
TypeScript, Monospace and LiveView source together.

The final targeted browser probe passed desktop 1440-pixel and mobile 390-pixel
layouts in both light and dark themes, contained tabs, character/line grid,
contrast, origin-only resources, repeated EOF polling, disconnect/reconnect and
hide/destroy lifecycle. The command used the disposable local Phoenix and
WebSocket fixture with `/tmp/overalls-boot-log-ui-targeted.py`; its record is
`/tmp/overalls-boot-log-ui-browser-final.log`, with four screenshots under
`/tmp/overalls-native-boot-log-browser/final-artifacts/`. The probe exercises the
actual read-only boot-log browser view and transport lifecycle, but does not
compose a native pending/failed guest, Lilly's file authority or a NixOS journey.

At clean revision `589ff7fe5`, complete Marshall `mix precommit` passed 1,690
checks (244 properties and 1,446 tests), with four exclusions, all 24 Covenant
obligations, terminal JavaScript 36/36, workspace 9/9 plus strict TypeScript,
Monospace and forced Dialyzer with zero errors or skips. The source hashes
remained unchanged throughout that run. Its record is
`/tmp/overalls-native-integration-marshall-precommit-589ff7fe5-final.log`.
The matching Lilly gate passed 610 checks (115 properties and 495 tests),
Covenant and forced Dialyzer with zero errors or skips, recorded at
`/tmp/overalls-native-lilly-589ff7fe5-precommit.log`. Later source changes need
their own checks; these local gates do not establish guest or fleet acceptance.

The final complete Lilly `mix precommit` passed all 608 checks (115 properties
and 493 tests), Covenant coverage and forced Dialyzer with zero errors or skips.
Its record is `/tmp/overalls-boot-log-lilly-precommit-final.log`, using the
pinned root development environment with two schedulers. Two earlier complete
attempts each hit a different existing framed-channel timing race; those files
passed seven isolated checks and the final complete run passed without source
changes for either failure. These results establish the reviewed local suite,
not native host isolation or production delivery.
