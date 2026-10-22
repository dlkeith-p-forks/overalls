---
digest: ad304114da706e2daaf6296aac5c058376e50742cc378ad4fc2a9d475d485124
disposition: updated
kind: chapter
mapping_digest: null
path: marshall/priv/hldd/06-workflows.md
reviewed_chapters: {}
state: present
version: 2
---

Clone cancellation of a still-queued request now also closes its cleanup obligation (Cloning.cancel!/1), matching a refused queued head; previously such a request stayed cleanup-pending so every advance and the minute reconcile trigger raised while recording a prune effect for an absent host. Found by the queue-history property after its timeout tag moved its derandomized seed; a deterministic regression test pins the minimal history. 06-workflows documents the rule; the clone scenario and regenerated coverage chapter cite the regression test.
