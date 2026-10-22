---
digest: bdcfccb00c6f036b3fb9f529813849924bb8f96b34448d724073a0aea3c175fb
disposition: updated
kind: chapter
mapping_digest: null
path: marshall/priv/hldd/07-guests.md
reviewed_chapters: {}
state: present
version: 2
---

Adds the illumos vioif receive descriptor budget (patch 0005): MTU-sized single-cookie receive buffers without guest receive offload and loans capped at half the buffers the ring holds, with an extracted-helper ASan/UBSan test and contract illumos-net-receive-budget. 07-guests documents the stall, the fix, the candidate transport/reset passes and that the promoted 45983bb7 image is unchanged.
