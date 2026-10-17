# Native lease withdrawal and workspace ownership fixture review

## Scope and architecture impact

This review covers the native executor lease-withdrawal history and the
workspace Git ownership oracle added to the disposable native service fixtures.
The changes exercise ADR-0100's existing executor fence and refusal boundary;
they do not change production authority, protocol fields, persistence,
admission, or recovery policy. Current-boot native execution remains a separate
pending obligation.

## Evidence

`native_control.py` models the ordered history from ordinary completion through
arming, accepted start, requested withdrawal, matching-heartbeat refusal (after
the fixture has observed the real HTTP 403), process-group death, and recovery
under a higher epoch and different executor identity. It redacts command text,
output, PIDs, executor identities and fences from the closed receipt. The unit
suite covers wrong and stale fences, result-attempt refusal before route/lease
validation, strict accepted-start-plus-15-second expiry, synchronized claims,
and the requirement that recovery is withheld until the whole old group is
absent.

`native_service_runner.py` observes only a root-owned parent/child marker and
bounded `ps` state, requiring one live process group and rejecting malformed,
reused, escaped, zombie or partial observations. Its checkout oracle verifies
the exact allowed repository and then creates an unrelated root-owned Git
repository; the managed user must receive Git's actual dubious-ownership refusal
with no stdout.

The local support suite passes **73 tests**. Ruff format/check and `ty` pass
for the fixture files, and the contract formatter/check reports all contracts
covered. These results establish fixture behavior only. No native
FreeBSD/OmniOS boot, current production lease withdrawal, or promotion receipt
is claimed by this review.

## Remaining gaps

Run the service fixture against each current native image and retain the full
receipt before changing ADR-0100's partial status or native admission. Physical
host recovery, independent-host execution, and production fleet acceptance are
outside this fixture.
