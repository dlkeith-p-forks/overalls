# Covenant contract verification review

## Scope

This review covers adding Covenant 0.2 to all twelve Elixir Mix applications, with contracts under each application and executable tests under `test/contract`.

## Architecture impact

The change adds development/test verification tooling only. It does not change domain boundaries, runtime dependencies, production configuration, persistence, authorization, transport, or deployment topology. Existing `CONTRACTS` and HLDD evidence remain authoritative.

## Evidence and limits

Static Covenant checks currently cover one active module-loadability obligation per generated component. This catches missing or renamed public modules. It does not establish native Rust/KVM behavior, physical isolation, multi-host recovery, browser behavior, or production evidence; those remain tracked in existing ADR and HLDD scenarios. Behavioral obligations should be added as the relevant subsystems evolve.

## Validation

`mix covenant.check --static` succeeds for the protocol application and the same layout is installed across all twelve applications. Full project precommit and repository checks remain the completion gates for this rollout.
