# Fleet Mosh and user lingering

## Scope and evidence

The [access module](../../../nix/modules/access.nix) enables the pinned NixOS Mosh
module on access-enabled hosts and systemd lingering for registry login users.
The upstream module supplies the package and UDP 60000–61000 firewall range.
The shared host profile includes Overalls; guest images are unchanged.

The [evaluation suite](../../../nix/tests/evaluation/access.nix) checks enabled
Mosh, its firewall range, lingering for admin and non-admin login users, and the
absence of implicit Mosh for disabled access and secrets-only compositions.
The [machine suite](../../../nix/tests/machines/access/driver.py) tests actual
cross-machine Mosh terminal input bootstrapped over administrative SSH port 2222,
user managers before login and after logout, and removed-account linger cleanup.
Fixture private keys are generated inside the VMs.

## Architecture impact and findings

ADR-0041's named-account policy, carried forward by ADR-0044, remains authoritative.
ADR-0046's administrative OpenSSH/Porsche separation is preserved. No replacement
ADR or change to application authorization, guest isolation or public APIs is needed.
No code/contract discrepancy was found in the changed scope.

Lingering intentionally starts user managers independently of interactive sessions.
New Mosh sessions authenticate through the existing SSH allowlist and keys; existing
sessions and processes still require separate termination after revocation. Recovery
permission alone supplies neither an account nor lingering. Removing an account
lets the upstream NixOS lingering service remove its stale entry.

## Verification performed

- `nix build -L .#checks.x86_64-linux.access-configuration .#checks.x86_64-linux.access --no-link --extra-system-features nested-kvm`
  passed, including the real two-VM test and driver lint/type checks.
- Direct evaluation of `nixosConfigurations.overalls.config` returned Mosh enabled,
  `ghuntley.linger = true`, administrative SSH `[2222]`, and UDP 60000–61000.
- `devenv shell -- node scripts/check_contracts.mjs format` passed; contract
  discovery for the access module and manual review of applicable obligations
  found no mismatch. The automated check establishes syntax/coverage only.
- `devenv shell -- elixir scripts/check_adrs.exs` passed (53 decisions; structure
  and local links only). `git diff --check` passed.

The initial machine fixture needed explicit pseudo-terminal dimensions for Mosh
and a completion check suitable for NixOS's oneshot lingering service. Those
fixture issues were corrected before the passing run. No Elixir application or
shared governance tooling was changed, so application precommit suites were not run.

## Decisions and follow-up

The user authorized fleet-host Mosh and lingering, excluding guest VMs. Use the
upstream defaults and existing access switch, without adding another Kittens option.
No production activation or provider firewall modification is included. Deployment
must permit UDP 60000–61000 beyond the host firewall and verify live connectivity;
local VM checks do not establish provider reachability or Overalls acceptance.
