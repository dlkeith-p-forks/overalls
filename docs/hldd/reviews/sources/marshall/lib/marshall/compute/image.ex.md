---
digest: 9a56e918c0d0eba60dec4ea569db2439d40600effb188b8664636ca57ae55b45
disposition: updated
kind: source
mapping_digest: c5d6b9e33b777c90bbc22e5608c825ce6977ecc6384e262a6c79b99b4af3d9a2
path: marshall/lib/marshall/compute/image.ex
reviewed_chapters:
  marshall/priv/hldd/02-control-plane.md: 8398bc3791875b6bc8cf22b6602a6efccb886c001a0f78d5a1500a3f5707ff3d
  marshall/priv/hldd/03-access.md: 5e197b8346180c9f65c712048048da17934c117a500fe63cfca781cd8933dae6
  marshall/priv/hldd/04-lifecycle.md: f3c40798f402b553640bb25852bcb205c327c87d7ad6735b4f1b243c5616b4a2
  marshall/priv/hldd/06-workflows.md: 37821743fdd87afefc8e10be455a247a49c10cb8fced69dd60588fe573bce8de
  marshall/priv/hldd/08-interactive.md: b913c892ca2cf07c4c54a9a981d18bdbf5302bccebd118551ce45304ea1a2b1f
  marshall/priv/hldd/11-agents.md: 7d24214acefb26fbd3b08ce582578fd007e6ffa4bd55d986293050de8605356d
  marshall/priv/hldd/15-monitoring.md: 185a956b7033aebff87a54c5b275b8368bd130205d7bb6a8cccb2ebdd4507c7a
  marshall/priv/hldd/17-reference.md: 9b7c3c0ba2c93d62cda3b8c5b3914af2ebbab0f7f9c1e6345bdb926d15c8e8cb
  marshall/priv/hldd/19-coverage.md: d61a73b3c1b32bb6174fe87bc3e4d127a41198a5c90b44b35b69fae6de84ac02
  marshall/priv/hldd/20-security.md: 6f505682683ace1b4b948ed6df21f924df87fd5a71793a725906722e7601a211
  marshall/priv/hldd/21-domains.md: 64cf0af44004d07c4e5c3402225bb22e5f4f29ae1e8a15b5c7690de8b769efb7
  marshall/priv/hldd/22-topology.md: b66172c618dc03b360046d5e1a6f2850265e5eb7acbe02e20c068a0efdf1569f
state: present
version: 2
---

Browser machine creation now refuses a size below the selected enabled image catalog minima before any setup thread exists, using the single Image.requirements_met?/2 rule that Compute admission now also calls (via Images.check_requirements/2). The form renders the existing localized machines-domain refusal and keeps the draft; ProvisionWorker keeps its transactional refusal. 08-interactive documents the pre-admission check, the default-OSS-creation scenario records the undersized test, and the coverage chapter is regenerated.
