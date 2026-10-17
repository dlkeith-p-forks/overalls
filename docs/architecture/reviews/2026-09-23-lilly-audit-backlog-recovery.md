# Lilly audit backlog recovery

## Scope and decision

[ADR-0074](../decisions/0074-durable-lifecycle-state-machines.md) requires
state and pending audit events to publish in one locked journal. An audit
backlog warning must not crash a VM actor or prevent an otherwise valid
transition. This change restores that accepted recovery behavior; it makes no
new architecture decision.

## Failure and correction

During fleet activation, Lilly VM actors repeatedly exited with `badarg` at
`erlang:binary_to_existing_atom/1`, and Lilly hit its service restart limit.
Eleven execution journals had exactly 48 pending events, the warning threshold.
The warning path converted the bare resource name to an existing atom, although
that atom need not exist in a production release. The same module already has
a closed mapping for event resource types. The warning now uses that mapping,
so it emits `:execution` and the journal transition continues.

The event retains only the catalogued resource type, ID and queue length. It
does not include journal payloads. The fix does not weaken the 64-event bound
or change audit acknowledgment, physical authority or durable publication.

## Verification and remaining work

The regression test advances a real execution journal through 48 pending
events, checks the structured warning metadata and confirms event 49 is
durable. Existing journal property tests continue to cover transition and
recovery histories. Lilly's full precommit passed with 392 tests, including 44
properties, and zero Dialyzer errors. Both production host deployment bundles
built. That revision activated and passed the updater's health probe, but
further observation found repeated Lilly restarts: restored actors rapidly
filled their journals to the 64-event bound before the independent audit
sender had time to run. The warning no longer crashed, but bounded
publication correctly refused further transitions.

On an authenticated control connection, the audit sender now drains inherited
pending events before restored actors reconcile. It signals readiness only
after a complete empty scan; the runtime accepts the signal only from its
current sender. Runtime readiness includes this gate, so deployment
verification cannot pass during recovery. Actor creation and ready callbacks
obey the same gate. The sender keeps its bounded 16-event offer and 128-path
scan; recovery uses a 100-millisecond interval between passes, while ordinary
delivery uses one second. Delivery errors retain the existing retry behavior
and never discard events. Production activation then exposed a second actor
write path: control-plane outcome acknowledgments were still forwarded while
actors were paused. They are now deferred until audit readiness; the pending
outcome remains in the next control report, so Marshall can repeat its
acknowledgment. Closed structured events record audit deferral reasons and
unexpected control HTTP status with a fixed response category, without
logging response bodies or credentials. The final focused suite passed with 16
tests, including two properties. The full suite passed 393 of 394 tests,
including all 45 properties; one 500-millisecond timing assertion completed at
the boundary under concurrent build load. Logging checks, compilation and
Dialyzer passed with zero errors. Both host bundles built. Fleet deployment
observation remains. ADR-0074 remains partially implemented for the wider
lifecycle milestone.

After activation, both hosts reached the healthy phase and Lilly remained
active with zero restarts. Most inherited events drained, but two full
execution journals continued to receive HTTP 500 responses from Marshall's
audit endpoint. Marshall now emits a catalogued diagnostic containing only
the exception class and top stack call site for this endpoint; exception
messages, arguments, request bodies and credentials remain excluded. The
remaining ingestion error must be diagnosed and corrected before audit
recovery can be considered complete. Marshall's diagnostic revision passed 922
tests, including 70 properties, zero Dialyzer errors, and its production
Overalls bundle built. Deployment observation remains.

The authentication privacy filter initially redacted the new diagnostic's
location fields along with its message. A narrow filter clause now preserves
only validated module/function atoms, exception class and bounded arity for
`lifecycle.audit_exception`; all other message content and arbitrary metadata
remain redacted. A property test varies an injected secret and checks both the
accepted diagnostic and the malformed-field fallback.
Marshall's full gate passed 923 tests, including 71 properties, with zero
Dialyzer errors; its production Overalls bundle built. Deployment observation
remains.

The safe diagnostic located the persistent HTTP 500 at
`erlang:binary_to_existing_atom/1`. Marshall's post-commit lifecycle notifier
converted host action and state strings to existing atoms, although the host
action atoms need not exist in Marshall's release. The notifier now uses a
total projection: known host labels receive fixed atoms, existing internal
labels retain their atoms, and previously unseen labels use closed fallback
atoms. The exact original strings remain in the durable audit row. A unit test
covers the observed `mark_unknown` event, and a property test checks that
unseen persisted labels cannot raise from the notifier. Marshall's full gate
passed with 925 tests, including 72 properties, and zero Dialyzer errors;
the production Overalls bundle built.

The fleet updater activated the correction on Overalls and Dungarees at
`7f6df2c1`; both reported the revision healthy. Lilly remained active with
zero restarts on both hosts. Overalls' execution journals fell from several at
the 64-event limit to a maximum of five pending events during observation.
No audit HTTP 500 or VM actor exit occurred after activation. One audit
transport deferral occurred during the service switch and then delivery
continued. This confirms recovery of the observed backlog failure; the wider
ADR-0074 milestone remains partial.
