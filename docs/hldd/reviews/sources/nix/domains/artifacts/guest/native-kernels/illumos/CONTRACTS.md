---
digest: 72ba9e8be1e9ce5c20750c438c06ac8878469465430f78bcd33234b1cb71ef75
disposition: updated
kind: source
mapping_digest: 05e1761038133f69f40af77d180940fa94168af5fea92478049f84f74b8e9d48
path: nix/domains/artifacts/guest/native-kernels/illumos/CONTRACTS
reviewed_chapters:
  marshall/priv/hldd/07-guests.md: bdcfccb00c6f036b3fb9f529813849924bb8f96b34448d724073a0aea3c175fb
  marshall/priv/hldd/12-configuration.md: 5318d494cf8479636aa2e2c3c61cb5505cb4cb8386e39b935cf62c62b997169f
  marshall/priv/hldd/13-deployment.md: 0bc4fe19bb9cdf60d5edc24c3777c7f54b170426d9ae5d1f611a2240053c3350
  marshall/priv/hldd/14-operations.md: 68c72d0e6fde22edd5d892f824dedd44f1843d68ece6c96ff5b3e2c1e50051c9
  marshall/priv/hldd/15-monitoring.md: 37f859a5a9ae74a8e7f39aa537f68287f5df97bcde5537669bbf53418c2064f9
  marshall/priv/hldd/16-recovery.md: 194fe77196ac4a25ab764d5cf4aee7558da547cd7b59726f32a302019b26136c
  marshall/priv/hldd/17-reference.md: 7d88fca8dbe56f67c71ea207b0ed860f4cfc005f7cb9f6ccde4ffe4bc718cda5
  marshall/priv/hldd/18-options.md: 56d6ff5dfa49ede786cba440d57100c75b721b23b1e0616e79d3df8205e5ac11
  marshall/priv/hldd/19-coverage.md: 0cb3df7d454cd48dcb9c1ddea347951c2eb63843284bbc76dc24f01e680faad9
  marshall/priv/hldd/20-security.md: 6f505682683ace1b4b948ed6df21f924df87fd5a71793a725906722e7601a211
  marshall/priv/hldd/21-domains.md: 64cf0af44004d07c4e5c3402225bb22e5f4f29ae1e8a15b5c7690de8b769efb7
  marshall/priv/hldd/22-topology.md: b66172c618dc03b360046d5e1a6f2850265e5eb7acbe02e20c068a0efdf1569f
state: present
version: 2
---

Adds the illumos vioif receive descriptor budget (patch 0005): MTU-sized single-cookie receive buffers without guest receive offload and loans capped at half the buffers the ring holds, with an extracted-helper ASan/UBSan test and contract illumos-net-receive-budget. 07-guests documents the stall, the fix, the candidate transport/reset passes and that the promoted 45983bb7 image is unchanged.
