# Administrator operational status

## Scope and architecture impact

This extends [ADR-0058](../decisions/0058-administrative-authority.md) with a
read-only operational projection for image availability, Audi ingress, Porsche
gateway state and fleet monitor credential expiry. It adds no new execution
authority and keeps deployment enrollment, secret installation and private-key
custody outside Marshall.

## Evidence

`Marshall.Administration.Operations.snapshot/1` rechecks `admin_read`, reads at
most 128 rows per resource and explicitly selects redacted fields. The
`/admin/operations` LiveView refreshes every 30 seconds and displays image
identity/availability, gateway generation, Audi service state, route expiry,
issuance status, DNS publication revisions and monitor credential
expiry/revocation metadata. Token hashes, secret digests, host keys, certificate
contents, DNS proofs and order URLs are not selected or rendered.

Lifecycle and relocation coordinator paths now record administrator actions in the
same transaction as the durable operation or reservation. Focused compute tests
cover commit and idempotent replay; the current full-gate checkpoint is 618 tests.

## Verification and remaining obligations

The administrator-only LiveView test exercises the snapshot against the real
resource set and checks redaction. Deployed revision/updater state still needs
deployment metadata from the host updater; this page does not infer it from
collector observations. The latest Marshall gate passed 611 tests (50
properties) and Dialyzer completed successfully.
