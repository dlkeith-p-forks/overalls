# Overview newsletter review

## Scope

This review covers the authenticated Overview newsletter invitation, the
account-wide dismissal preference, and Marshall's fixed server-side Ghost
subscription client.

## Architecture impact

The change adds one private boolean to the existing User resource and one
presentation-only integration module. It does not create a new domain,
protocol, host, service, or authorization boundary. The external boundary is
explicit: browsers submit only the fixed no-JavaScript fallback form, while
Ghost API calls originate from Marshall and return fixed safe outcomes.

## Evidence and limits

The migration, Ash action, LiveView behavior, Req client, Hegel input and
success/failure properties, and security-header expectations are versioned with
the feature. External Ghost delivery, provider availability, and production
mail receipt remain unverified by local BEAM tests.

The final focused Marshall run passed **40 tests** in **12.4 seconds**, seed
**587216**. It includes the newsletter dismissal, Overview LiveView and
newsletter property suites alongside Peach, PaperTrail and Galileo fixtures.
The exact seven-file command is recorded in the
[reflection review](2026-10-18-guest-reflection.md); its captured output is
`/tmp/marshall-focused-final.log`. Each of the three newsletter Hegel properties
runs **100 cases**. The run records self-only monotonic dismissal, stale and
foreign actor refusals, bounded mailbox validation, injected Ghost success and
failure mappings, and removal of the invitation in the local LiveView fixture.
It does not establish a packaged browser remount or external Ghost delivery.
