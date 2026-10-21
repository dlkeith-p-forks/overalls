---
title: Structured diagnostics and audit review
date: 2026-10-21
status: reviewed
---

## Scope

This review covers the shared diagnostics SDK, application Events catalogs, OTP
Logger privacy filters, request accounting, Marshall, Lilly, Audi, Brady,
Enrico, Galileo, Peach, Porsche, Susan and Ziggy changes in this revision.

## Findings and decisions

The changes preserve ADR-0042's catalogued structured logging boundary and
ADR-0149/0159's typed protocol and ordered compatibility rules. Diagnostic
metadata remains bounded and excludes credentials, payloads, command arguments,
terminal bytes and exception text. Success diagnostics for transactional work
now follow the outer commit; Susan's mandatory audit writes remain atomic and
security refusals remain fail-closed. Operational producer and cache metrics
remain fail-open and report recording gaps separately.

OTP status formatting was hardened for OTP 29's exact-key callback contract:
status keys are preserved, values are redacted, and logger history is cleared.
This is evidence for diagnostic privacy only; it does not establish native
isolation, durable audit retention, or fleet availability.

## Validation and remaining gaps

Focused application suites, logging checks, Covenant checks and Dialyzer runs
are recorded in the task logs. Long Hegel and native/Nix integration suites
remain environment-dependent; one known Inception failure remains excluded by
repository guidance. Review manifests under `/tmp/diagnostics-review-*.tsv`
record file-level coverage and must not be treated as runtime evidence.

No ADR decision was changed. Follow-up work remains for complete native audit
retention and machine-level diagnostic volume/retention acceptance.
