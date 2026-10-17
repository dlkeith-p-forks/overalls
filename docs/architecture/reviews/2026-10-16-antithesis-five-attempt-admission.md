# Antithesis five-attempt bootstrap admission

Date: 2026-10-16

## Decision and scope

The hosted Antithesis campaign ledger now admits up to five active remote
attempts. This supports concurrent bootstrap validation of the selected
control-core, repository-origin, and access-smtp Compose profiles, with two
independent control-core repetitions. The limit applies only to the
verification campaign ledger; it does not change Marshall, Lilly, protocol,
deployment, or production runtime behavior.

The immutable build identity, per-profile baseline lineage, mutant-selection
serialization, exact duration policy, and triage-receipt requirements remain
unchanged. The campaign remains fail-closed when its global attempt ceiling is
exhausted.

## Evidence

- antithesis/verification/campaign.py enforces the five-active bound.
- Campaign tests cover five reservations and refusal of a sixth, including
  cross-configuration admission.
- The verification README and campaign review describe the bound and its
  evidence boundary.
- The HLDD reference records concurrent hosted bootstrap validation without
  claiming production or property acceptance.
- Verification tests, contract checks, ADR checks, HLDD checks, views, and the
  all-file precommit gate pass on this worktree.

## Architecture impact

No accepted architecture decision changes. This is an operational verification
capacity change, with no new domain, resource, protocol, authorization,
persistence, isolation, or deployment boundary. Hosted run results remain
operator-derived triage evidence and do not establish production behavior.
