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
