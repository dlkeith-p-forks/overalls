# Administrator workload console

## Scope and architecture impact

This extends [ADR-0058](../decisions/0058-administrative-authority.md) with a
bounded fleet workload projection and explicit administrative entry points for
existing lifecycle, resize and relocation coordinators. It reuses the current
VM safety checks and does not create an administrator-only mutation path around
capacity, placement, terminal fencing or idempotency.

## Evidence and findings

`Marshall.Compute.AdminViews` reads at most 100 current VMs per page, projects
owner identity and resource/state fields, and excludes archived identity,
placement internals, credentials and terminal data. Owner email lookup uses the
existing internal account projection. `Admin.WorkloadsLive` refreshes every 15
seconds and delegates lifecycle and relocation commands to the same `Compute`
actions used by the customer UI; resize links to the existing generation-bound
resize flow.

The Cedar adapter gives only the read projection `admin_read` authority. The
mutation actions still use the normal VM `provision` decision and coordinator
checks, so an administrator cannot bypass host locks, relocation exclusion,
capacity admission, terminal invalidation or idempotency rules.

## Verification and remaining obligations

The workload projection was exercised with a real provisioned VM and owner
projection, including redaction assertions. The LiveView test covers anonymous,
ordinary-user and administrator routing. The workload table now links directly
to the existing per-VM details, application-access and terminal surfaces. Scale
benchmarking and native relocation acceptance remain open. The full Marshall
gate passed 618 tests (50 properties) and Dialyzer completed successfully.
