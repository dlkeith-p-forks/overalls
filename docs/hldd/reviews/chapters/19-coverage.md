---
digest: 9685b62803a944d62c80bdf31782307c869d1234b55ba701efe43464c2765282
disposition: updated
kind: chapter
mapping_digest: null
path: marshall/priv/hldd/19-coverage.md
reviewed_chapters: {}
state: present
version: 2
---

Clone cancellation of a still-queued request now also closes its cleanup obligation (Cloning.cancel!/1), matching a refused queued head; previously such a request stayed cleanup-pending so every advance and the minute reconcile trigger raised while recording a prune effect for an absent host. Found by the queue-history property after its timeout tag moved its derandomized seed; a deterministic regression test pins the minimal history. 06-workflows documents the rule; the clone scenario and regenerated coverage chapter cite the regression test.
