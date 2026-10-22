---
digest: b913c892ca2cf07c4c54a9a981d18bdbf5302bccebd118551ce45304ea1a2b1f
disposition: updated
kind: chapter
mapping_digest: null
path: marshall/priv/hldd/08-interactive.md
reviewed_chapters: {}
state: present
version: 2
---

Browser machine creation now refuses a size below the selected enabled image catalog minima before any setup thread exists, using the single Image.requirements_met?/2 rule that Compute admission now also calls (via Images.check_requirements/2). The form renders the existing localized machines-domain refusal and keeps the draft; ProvisionWorker keeps its transactional refusal. 08-interactive documents the pre-admission check, the default-OSS-creation scenario records the undersized test, and the coverage chapter is regenerated.
