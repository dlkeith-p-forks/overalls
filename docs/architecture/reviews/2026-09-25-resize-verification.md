# Resize user-journey verification

## Scope and architecture impact

Campaign improvement 010 extends evidence for the resize behavior inherited from
[ADR-0051](../decisions/0051-vm-resizing.md) by
[ADR-0053](../decisions/0053-vm-disk-limit.md). The accepted stop, physical resize,
optional restart, current management authority and immutable request contracts
remain unchanged. No schema, transport, capacity policy or architectural decision
is introduced. Disk shrinking, cancellation and an SSH resize command remain
explicitly outside the accepted behavior.

## Findings and contract review

**Corrected confirmed disk display (low).** The resize page accepted exact aligned
fractional GiB values and displayed their pending target precisely, but its
confirmed-resource panel used integer division. A 2 GiB + 4096 byte disk appeared
as 2 GiB. The focused pre-fix run with seed `10010` reproduced the failed assertion
for `2.000003814697265625 GiB disk`. The display now uses the same integer-only
formatter as the form and pending target. No storage allocation changes.

Reviewed root, Marshall/test/Web, Nix/test and documentation contracts, resize
coordinator and request transitions, the physical outcome coordinator, shared
shape/drive/bundle bounds, current authorization and browser draft contracts.
The generated tests use actual Ash actions and sandboxed PostgreSQL. Their
independent size oracle charges 64 MiB VMM memory, 1 GiB portable boot bundle,
and the additional fixed 256 GiB Inception drive exactly once. A resize adds only
the root disk growth delta. Synthetic outcomes establish coordinator behavior,
not native disk safety.

Generated histories vary profile, original power, CPU/RAM target, 4096-byte disk
growth, unknown stop/resize receipts, phase retries, changed capacity and uncertain
restart fencing. Complete VM/version, placement, reservation, address, operation,
physical receipt, resize request, sharing/version/change and audit rows are
compared after refusals and exact replays. A valid stale physical receipt is
retained as history while all other authority rows remain unchanged. Invalid
placement, epoch and target-size evidence rolls back. Separate generated grant
histories prove original receipt identity cannot bypass manager downgrade or
revocation, and automatic phases retain the actor who authorized the retry.

## Native journey and limits

The new `resize-browser` check uses the source-built nine-node fleet with three
Marshall replicas, PostgreSQL, verified HTTPS proxy, browser, two Lilly hosts and
local service prerequisites. Its independent composed driver keeps native type
and lint checks enabled. The Audi-compatible guest and real trust/roster services
satisfy existing readiness requirements; the fixture does not bypass trust.

The browser creates an ordinary-user OSS VM, retains a resize draft across reload,
submits a running resize from 4 GiB to 5 GiB + 4096 bytes, and checks the exact confirmed
value after completion and reload. An independent stale draft must refuse with
no durable intent/allocation effects. A second browser resize grows the stopped VM to 6 GiB
without restarting it. A foreign identity sees no resize form. Privileged bounded
fixture probes enter the actual guest to seed and verify preserved data, exact
block length, CPU count, bounded guest MemTotal and filesystem growth;
the running Firecracker API also confirms exact vCPU and memory configuration. Their terminal bytes remain private.

Existing native ZFS interruption/neighbor evidence and the Customer SSH readiness
resize scenario retain their original revisions and scopes. This improvement does
not rerun the complete interruption matrix, Ubuntu or native Inception resizing,
and cannot establish independent physical-host acceptance or production rollout.
The guest probes are fixture access, not a new user-facing terminal acceptance claim.

The selected real image manifest requires 3,725,295,616 disk bytes and 512 MiB
memory. The fixture therefore starts at 4 GiB; a Nix assertion rejects an image
whose minima no longer fit those inputs. The original authored 2 GiB fixture
request was corrected by inspecting the actual closure before native execution.
The synthetic 2 GiB + 4096 byte display regression retains its independent scope.

## Integration scope

Published main `5bce9478a956f7dc162e1516c2ce088c6a27f090` is included before
this improvement's final gate. Its ADR-0123 remembered-browser and MFA changes
retain their own recorded evidence. The resize browser uses ordinary accounts
without enrolled authenticators and does not claim new remember-cookie coverage.

## Execution record

- Pre-fix focused run: seed `10010`; the confirmed fractional-disk assertion failed.
  An early draft property also rejected its own malformed unknown-outcome reason;
  the fixture now uses the protocol's `unknown` reason. This was not a production
  outcome-handling defect.
- After display fix: 4 passed (1 property, 3 tests), seed `10010`, 10.6 seconds.
- Final focused coordinator/LiveView run: **14 passed (2 properties, 12 tests)**,
  seed `10010`, 16.0 seconds.
- Combined tests passed **1,041 checks (99 properties, 942 tests), two excluded**,
  seed `807569`, 411.8 seconds, on published main `5bce9478` plus this improvement.
  Full `mix precommit` completed with exit 0. Forced Dialyzer reported zero errors,
  zero skips and zero unnecessary skips; analysis took 71.95 seconds after refreshing
  the relocated PLT.
- The final native driver and separately copied Playwright helper passed their
  pinned type/lint builds.
  The native type checker rejected an early implicit JSON dictionary narrowing;
  explicit validated string keys now pass without casts or exclusions.
- Browser completion is recorded only after successful Chromium close; the driver
  waits for the subprocess to be dead before requiring its final zero exit status.
- The first native attempt, derivation
  `/nix/store/8izw9dwq93rhryh2bp7r719hvgj5vhl9-vm-test-run-kittens-resize-browser.drv`,
  completed trust/capacity setup and ordinary browser creation of a running guest,
  then failed a fixture identity query before any resize. Host and pool are
  persisted on the current placement, not the VM row. All three identity reads now
  join that placement; PostgreSQL prepared all 15 distinct driver queries against
  the migrated test schema in read-only transactions. The failed fleet cleaned up
  all nine machines in 3.44 seconds. This attempt is not resize acceptance evidence.
- **Native resize browser journey passed in 281.32 seconds**, followed by successful
  cleanup of all nine machines in 3.45 seconds. Running growth, retained exact
  fractional display after reload, unchanged identity/data, stale-draft refusal
  with unchanged durable inventories, stopped growth without implicit restart,
  foreign-user refusal and the later explicit boot all passed. Firecracker's live
  configuration and the guest independently confirmed CPU/memory; the guest also
  confirmed exact disk lengths and filesystem growth.
  The executed derivation was
  `/nix/store/9qrpm0mmvqj1j19k9d7g05m2z375msax-vm-test-run-kittens-resize-browser.drv`,
  with output
  `/nix/store/c3268280lfj9j9rfabcaimkrj8g3mwid-vm-test-run-kittens-resize-browser`.
  It contains the corrected placement queries on published main `5bce9478` plus
  this improvement. Subsequent scenario/review bookkeeping changes evidence text,
  not the application or fixture behavior exercised by this run.
