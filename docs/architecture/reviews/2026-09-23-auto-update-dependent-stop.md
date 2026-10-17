# Automatic update dependent-stop recovery

## Scope and architecture impact

This review covers the automatic host updater's consumer and secret-unit stop
phase in [runtime.py](../../../nix/domains/system/auto-update/runtime.py). It affects
the recovery implementation under ADR-0036 and the host activation flow under
ADR-0043. It preserves their existing authority, candidate, migration,
rollback and health contracts; no replacement decision is needed.

## Finding and resolution

### High — one systemd transaction could cancel dependent stop jobs

On Overalls, a candidate activation submitted all active consumers in a single
`systemctl stop` command. Some units stopped as dependencies of others;
systemd canceled their separately queued stop jobs and returned a failure even
though part of the stack was down. Repeated updater attempts then failed
activation and left application roles unavailable until their current-generation
units were restarted. This was an implementation defect in the accepted
recovery path.

The updater now stops each still-active unit in its own transaction under one
180-second deadline. It rechecks all requested states after a pass. A production
activation showed that stopping a dependent later in the pass can leave an
earlier secret unit active after its job was canceled, so the updater makes up
to four passes over still-active units. It publishes the bundle only when every
requested unit is inactive or failed; a persistent active unit fails activation.
The same logic covers runtime consumers and existing secret units.

## Verification

- Focused Python tests cover a dependency cascade, a canceled job that already
  stopped its unit, a retry after a later dependent stops, and a canceled job
  that persistently leaves a consumer active.
- The full `auto-update` Nix machine check passed, including actual Git polling,
  activation, failure recovery and unchanged-revision behavior.
- Repository-wide Ruff format, Ruff check and ty hooks passed after the change.

These tests establish the stop sequence in isolation and in the machine
fixture. A production activation of this revision remains the deployment check.
