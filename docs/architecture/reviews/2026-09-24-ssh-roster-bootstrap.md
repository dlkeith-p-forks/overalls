# SSH roster bootstrap review — 2026-09-24

## Scope and architecture impact

Fix the production clone/source restart dependency between guest SSH readiness
and completed-running roster authorization. ADR-0115 supersedes only the roster
bootstrap requirement of ADR-0110. ADR-0051 resize and ADR-0055 clone completion,
capacity and restoration semantics remain unchanged; ADR-0113 trust installation
still precedes guest networking. No persistence migration is introduced.

## Findings and resolution

- **High — startup dependency:** the deployed SSH guest requires a roster before
  sshd, while clone/resize execution waits for sshd before reporting running.
  A scoped bootstrap identity now includes current generation/operation and
  requires Lilly's real physical boot proof, independently renewed command and
  runtime, authenticated host, and Marshall's exact current operation.
- **High — scope isolation:** ordinary bindings cannot acquire bootstrap powers.
  Only the exact roster GET selects the version-2 connector. Ziggy and Marshall
  reject extended identities on key/login and other service paths. The frontend
  replaces guest identity headers and its guard renews the same scope/binding.
- **Medium — diagnostic loss:** readiness failures previously collapsed into
  execution_failed and cleanup removed the boot log. Catalogued reason/stage
  events and bounded private log retention preserve evidence without exporting
  terminal bytes. Cleanup lock contention retains previous observations.
- **Medium — readiness contention:** native Ubuntu execution exposed placement
  lock contention between a roster proof and readiness recheck. Such contention
  now retries directly before failure fencing; it is not evidence of a bad
  guest. The final native run includes this correction.
- **Medium — native coverage:** existing cloning fixtures omit SSH integration.
  Dedicated NixOS/Ubuntu checks now use SSH-enabled customer guests, real clone
  and resize actions, a roster outage, and persistent file/account checks.

## Validation

- Marshall pending-boot roster regression reproduced unauthorized before the
  change and passes after it.
- Full `mix precommit` passed in Protocol (202), Lilly (406), Audi (134), Ziggy
  (37), and Marshall (936, two host-only exclusions), including properties,
  compiler, contract, logging and forced Dialyzer checks. Marshall's distributed
  and JavaScript checks also passed. Lilly's gate was rerun after preserving logs
  across a later stop. Every Dialyzer run reported zero errors and unused skips.
- `prek run --all-files` passed logging checks, Ruff, Ruff format and ty. Fleet
  fragments receive Ruff formatting/lint/annotation checks. The existing fleet
  runner sets `skipTypeCheck = true`; composed-driver static typing remains an
  existing gap, separate from the executed native assertions.
- The initial native fixture stopped Ziggy, which correctly prevented launch
  at the host health gate. The revised fixture rejects guest private HTTPS in
  an isolated nftables table while retaining local health probes; it restores
  access in `finally`. It also tests a full readiness timeout, retained boot log,
  stopped VMM, and authorized retry with the same placement and guest data.
  The console probe retries boundedly while the guest terminal service starts.
  Bootstrap fixtures use the ordinary 64 MiB/s transfer limit; existing relocation
  fixtures retain their slower write-during-copy window.
- Both final `ssh-bootstrap-fleet` and `ssh-bootstrap-ubuntu-fleet` checks passed
  on x86_64 KVM (combined build exited 0 after 858 seconds). These exercised the
  actual packages, authenticated fleet, private networking, Firecracker guests,
  clone/resize workflows and timeout recovery; data and account ownership
  survived. Both production system closures also built successfully.
- Production deployment and recovery passed as recorded below. Synthetic
  executor tests alone do not establish physical confinement or native boot
  acceptance.

## Final contract review

Reviewed the strict codecs, connector worker limits/UID check, request routing
and renewal, runtime/actor snapshots, Driver claim/intent/boot/confinement proof,
and Marshall's authenticated transaction through current Cedar candidates.
Bootstrap proof is checked outside the actor loops and cannot satisfy the
ordinary service decoder. Completed operations require their immutable running
receipt. Pending-operation authority cannot independently publish running or
release capacity. Failure events contain catalogued atoms/identifiers only;
the existing bounded log stays private until launch or deletion. No contract
violation was found in the changed scope. Physical acceptance is separately
tracked above.

## Production recovery

`1f71c7855d141c2e7506414a41f0aa251bba84be` was merged to main, pushed, and
activated through the normal updater on Overalls, then Dungarees. Both reported
that revision as healthy with Lilly, Audi private and Ziggy active. Overalls'
Marshall was healthy as well. The first manual updater attempt correctly failed
because its required timer was paused; restoring the timer allowed the normal
preflight, activation and health gates to complete. Both updater timers remain
active. There were no unrelated running VMM units on either host at rollout, so
this deployment does not add evidence for unrelated guest process survival.

Recovery used the current request owner's authorized `Marshall.Compute.retry_clone`
and destination `Marshall.Compute.lifecycle` actions in isolated operator mode.
It did not modify database rows directly or rewrite old outcomes.

| Machine | Current placement | Recovered generation | Result |
| --- | --- | --- | --- |
| Source `1fe59350-8b62-43a8-bb70-4b927e4d7ba6` | `1741bc80-1e3c-4b7e-a1c5-b801c1109136` | 4 | Running; boot-bound guest readiness passed |
| Destination `e93801d3-90ef-4f20-84b7-b44cd5ef68d2` (`test`) | `77d84d25-76da-4029-8b7c-61f1e8eb9e5f` | 3 | Running; boot-bound guest readiness passed |

The actual `Lilly.VM.Driver.ready/4` probe verified current owned boots, confined
VMMs and guest service readiness, including SSH, for both machines. Clone request
`a13ef7d4-ce75-4265-91c1-17599b01eff8` recorded source restoration at
13:25:58 UTC and completed at 13:26:05 UTC on 2026-09-24: inactive, no failure,
and finished cleanup. Each running VM has one retained compute/disk reservation.

Before/after ZFS dataset GUIDs match: source `12463777149971300377`, destination
`16685052377969033445`. The two original completion outcomes retain identical
observation hashes. No disk replacement, guest image migration or schema change
was needed. The existing fleet composed-Python typing gap noted above remains;
production user SSH login with a private user key was not exercised by this
operator readiness probe.
