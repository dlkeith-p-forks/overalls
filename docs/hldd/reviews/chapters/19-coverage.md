---
digest: 347130fc1c617f8d232fc8b20221c6f5a2111e5e05a7fcc9b2d0f286081c4cc9
disposition: updated
kind: chapter
mapping_digest: null
path: marshall/priv/hldd/19-coverage.md
reviewed_chapters: {}
state: present
version: 2
---

Lyra advertises artifacts-v1 and runs the internal artifact_stage command, opening staged files without following links (ssh_files open_no_follow), validating paths and per-file SHA-256, and accepting files up to the 64 MiB per-publish limit Marshall sends; attachment transfer requests use their 360,448-byte body bound. Ziggy forwards the bounded artifact_chunk executor RPC route beside attachment/transfer, and control.ex is reformatted only. Chapters 10-services and 11-agents describe the staging path, capability and limits, and 17-reference and 19-coverage list the Ziggy chunk-route and Lyra tests.
