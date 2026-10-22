---
digest: 1e28d6e2b6a0efe97a68d144cc71a5ef6bea5d45a1b039f42525028454ebf337
disposition: updated
kind: source
mapping_digest: f5fc9d76317e24062e0e2b16713ab5e149eff5538f68346d30e34292f21dbae4
path: lyra/src/CONTRACTS
reviewed_chapters:
  marshall/priv/hldd/08-interactive.md: 368f33fbb31c849c8558e3988b6199db2635f59e76065042873e1de42c9eaef3
  marshall/priv/hldd/09-network.md: 225196b393bb0b27d8bdc3bac0a787b869f7d22e9d48ed72dc67ccec6d9ae79b
  marshall/priv/hldd/10-services.md: f9b33deb62ddad83d0c957305d3c23949679032392fbe4c4f0b8381dc86b756d
  marshall/priv/hldd/11-agents.md: 7d24214acefb26fbd3b08ce582578fd007e6ffa4bd55d986293050de8605356d
  marshall/priv/hldd/17-reference.md: f1763e53aa081b752df936173e2041b4cda3351ada40a096cc2eac99b020c4da
  marshall/priv/hldd/19-coverage.md: 347130fc1c617f8d232fc8b20221c6f5a2111e5e05a7fcc9b2d0f286081c4cc9
  marshall/priv/hldd/20-security.md: cf1337ba6e78c460d2d00a269abbe3ad011151401179263eb51ab2d90bb4948f
  marshall/priv/hldd/21-domains.md: 64cf0af44004d07c4e5c3402225bb22e5f4f29ae1e8a15b5c7690de8b769efb7
  marshall/priv/hldd/22-topology.md: b66172c618dc03b360046d5e1a6f2850265e5eb7acbe02e20c068a0efdf1569f
state: present
version: 2
---

Lyra advertises artifacts-v1 and runs the internal artifact_stage command, opening staged files without following links (ssh_files open_no_follow), validating paths and per-file SHA-256, and accepting files up to the 64 MiB per-publish limit Marshall sends; attachment transfer requests use their 360,448-byte body bound. Ziggy forwards the bounded artifact_chunk executor RPC route beside attachment/transfer, and control.ex is reformatted only. Chapters 10-services and 11-agents describe the staging path, capability and limits, and 17-reference and 19-coverage list the Ziggy chunk-route and Lyra tests.
