---
digest: 5f501aa106883514c63d03167c744e6bf9fde45329df90a34cbe9581c1d6bd86
disposition: updated
kind: source
mapping_digest: c5d6b9e33b777c90bbc22e5608c825ce6977ecc6384e262a6c79b99b4af3d9a2
path: marshall/lib/marshall/compute/reservation.ex
reviewed_chapters:
  marshall/priv/hldd/02-control-plane.md: 8398bc3791875b6bc8cf22b6602a6efccb886c001a0f78d5a1500a3f5707ff3d
  marshall/priv/hldd/03-access.md: 3f9fae617239f90a3b94a44aa662f107c43be08ac7a196f1ee952deb54343acd
  marshall/priv/hldd/04-lifecycle.md: f3c40798f402b553640bb25852bcb205c327c87d7ad6735b4f1b243c5616b4a2
  marshall/priv/hldd/06-workflows.md: 37821743fdd87afefc8e10be455a247a49c10cb8fced69dd60588fe573bce8de
  marshall/priv/hldd/08-interactive.md: 368f33fbb31c849c8558e3988b6199db2635f59e76065042873e1de42c9eaef3
  marshall/priv/hldd/11-agents.md: 7d24214acefb26fbd3b08ce582578fd007e6ffa4bd55d986293050de8605356d
  marshall/priv/hldd/15-monitoring.md: 37f859a5a9ae74a8e7f39aa537f68287f5df97bcde5537669bbf53418c2064f9
  marshall/priv/hldd/17-reference.md: 7d88fca8dbe56f67c71ea207b0ed860f4cfc005f7cb9f6ccde4ffe4bc718cda5
  marshall/priv/hldd/19-coverage.md: 0cb3df7d454cd48dcb9c1ddea347951c2eb63843284bbc76dc24f01e680faad9
  marshall/priv/hldd/20-security.md: 6f505682683ace1b4b948ed6df21f924df87fd5a71793a725906722e7601a211
  marshall/priv/hldd/21-domains.md: 64cf0af44004d07c4e5c3402225bb22e5f4f29ae1e8a15b5c7690de8b769efb7
  marshall/priv/hldd/22-topology.md: b66172c618dc03b360046d5e1a6f2850265e5eb7acbe02e20c068a0efdf1569f
state: present
version: 2
---

Machine pages read through DecisionSnapshot batches with memoized principal, owner, grant, thread, team and projection reads, batched prefetch and catalog reads, user-leading indexes, refresh-after-completion and connected-only overview loading, per-view refresh telemetry and a fixed agent_stuck_turns multiplier; the access chapter, regenerated coverage and the batched-machine-page-decisions scenario describe them.
