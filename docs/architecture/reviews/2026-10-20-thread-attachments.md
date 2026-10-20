# Thread attachments architecture review

The attachment feature adds Marshall-owned metadata and an encrypted blob adapter.
PostgreSQL remains authoritative for thread ownership, lifecycle state, idempotency,
and audit identity; the blob store never grants access. Downloads recheck current
thread Cedar authority and use bounded capabilities. Stop and suspension purge
message-board posts only; archived threads retain authorized attachments and
deletion cleanup is retryable. Hegel properties cover transition closure,
idempotency, redaction, and available-only reads. Native blob durability and
malware scanning remain deployment gaps.
