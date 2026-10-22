---
digest: 7b6bafc9b2f1bf9eff4aaf65a1802f13a83c7a8f89baaea9083e775a4841bfd9
disposition: updated
kind: chapter
mapping_digest: null
path: marshall/priv/hldd/05-storage.md
reviewed_chapters: {}
state: present
version: 2
---

Chapter 05-storage adds the artifact blob storage section: content-addressed SHA-256 blobs held as bounded PostgreSQL chunks under existing backups, staged upload chunks with expiry, batched purge and the unreferenced-blob sweep; no Lilly storage path, protocol or host behaviour changes.
