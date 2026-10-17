# ADR-0165: Activation restarts only changed units

- ID: ADR-0165
- Date: 2026-10-13
- Status: accepted
- Implementation: partial
- Components: auto-update runtime, auto-update NixOS module
- Supersedes: none
- Superseded by: none

## Context

ADR-0036 activation stopped every consumer, socket and secret preparation unit
before `nixos-rebuild switch` and restarted them afterwards, whatever the
candidate changed. On 2026-10-13 eight Marshall-only pushes restarted Lilly on
both hosts eight times; each restart dropped the control channel for about a
minute, exited every VM actor (`journal_lock_lost`) and discarded the
memory-only clone runtime state, while the guests themselves kept running.

## Decision

1. **Changed-unit detection.** For every consumer, secret preparation unit and
   activation socket, the updater compares the unit's store identity in the
   active system and the candidate: the real path of
   `etc/systemd/system/<unit>` and of each drop-in under `<unit>.d`. A unit
   changes when either differs or the unit exists on one side only.
2. **Secret bundles.** The manifest carries `bundleConsumers`, the units that
   require, bind to or are part of each secret preparation unit. A bundle
   whose staged files differ from the live bundle restarts its preparation
   unit and those consumers, and a preparation unit whose own definition
   changed restarts those consumers too, in order, rather than letting a
   `PartOf` stop take them down implicitly.
3. **Dropped consumers** (listed by the previous manifest only) are stopped.
   **Dependents restart too:** the manifest carries `consumerDependents`,
   the consumers that require, bind to or are part of each consumer, and the
   restart set is closed over it, and a socket is quiesced when its service
   is in that set. On 2026-10-13 the first activation with this rule failed
   on overalls: `marshall-fleet-relay.service` (unchanged,
   `Requires=marshall-overalls.service`) was retained with its listening
   socket, so stopping Marshall stopped the relay by propagation, the next
   connection on the public fleet address socket-activated the relay, which
   pulled Marshall back up, and the stop loop gave up (`activate_failed`;
   roles were restored). Stopping dependents and their sockets deliberately,
   as the previous stop-everything rule did implicitly, closes that gap.
4. **Everything else stays up.** Only the units in that set are stopped before
   the switch; a socket is quiesced only when it or its service restarts;
   unchanged secret preparation units are not stopped, so their `PartOf`
   consumers are not stopped either. Activation records
   `update.units_retained` with the count. Start-up after the switch still
   names every health unit and running consumer; starting a unit that stayed
   up is a no-op.

## Alternatives

- Letting `switch-to-configuration` decide restarts: rejected; the updater
  must order secret handoff, Marshall migration and role restoration itself
  and keep the stop deadlines of ADR-0036.
- Marking Lilly `X-RestartIfChanged=false`: rejected; a changed Lilly must
  restart, and the rule belongs in one place for every consumer.

## Consequences

A Marshall-only release leaves `lilly.service`, its credential preparation and
the transfer sockets running. A Lilly release still restarts Lilly exactly as
before. Manifests gain `bundleConsumers`; the runtime treats its absence as an
empty map, so an older manifest still activates with every bundle's consumers
decided by unit identity alone.

## Invariants and verification

- A unit whose file, drop-ins and bundles are identical in both systems is
  never stopped by activation.
- A changed unit, a dropped consumer and a consumer of a changed bundle are
  always stopped before the switch.
- Unit tests `nix/tests/machines/auto-update/unit.py` (`ChangedUnits`); the
  native `auto-update` test asserts the relay's PID survives a candidate that
  changes other units and that `update.units_retained` is recorded.

## Implementation evidence

- [runtime.py](../../../nix/modules/auto-update/runtime.py)
  (`unit_identity`, `Deployment.changed_units`, `units_to_restart`,
  `activate`), the [module manifest](../../../nix/modules/auto-update/default.nix)
  (`bundleConsumers`).
- Tests: [unit.py](../../../nix/tests/machines/auto-update/unit.py),
  [driver.py](../../../nix/tests/machines/auto-update/driver.py).
- Fleet evidence (a Marshall-only push leaving `lilly.service`'s
  `ActiveEnterTimestamp` unchanged) is recorded in the
  [storage churn review](../reviews/2026-10-13-storage-churn-and-capacity-damping.md)
  when it happens.

5. **Required oneshots do not restart at switch.** `overalls-resource-policy`
   names the deployment manifest in its command line and therefore changes
   with every release; `switch-to-configuration` restarting it stopped
   `lilly.service` (which requires it) by dependency propagation on overalls
   even in a Marshall-only release. The unit is `restartIfChanged = false`
   and `stopIfChanged = false`: the updater applies the policy itself after
   every switch and the unit still runs at boot.

## Rollout note (2026-10-13)

Activation runs in the *live* updater, so the dependents rule could not
deploy itself on overalls: the first changed-unit updater kept failing the
same way on every candidate that changed Marshall, with no out-of-band switch
authorized. The relay socket on overalls is now `PartOf=marshall-overalls.service`
([overalls configuration](../../../fleet/hosts/overalls/configuration.nix)),
which the live updater sees as a changed socket and quiesces, so the stop
completes and the updater carrying the dependents rule becomes live. Any
future change to the activation rule has the same one-release lag.

## Open questions

- Whether a changed `/etc` file read at runtime by an unchanged unit should
  count as a change; today only the unit definition and its bundles do.

## Related decisions

- [ADR-0036](0036-automatic-host-updates.md): activation ordering, deadlines
  and health checks, which this decision keeps.
- [ADR-0140](0140-event-driven-liveness-and-single-writer-views.md): a Lilly
  restart is slowness, never evidence of loss, but it still costs the control
  channel and the actors.
