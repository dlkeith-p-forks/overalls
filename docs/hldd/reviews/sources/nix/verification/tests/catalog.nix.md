---
digest: 6199d25f85df7c6801ac50a990884f4f228c555cd7c3bc5dcbabbf529d8a6c98
disposition: updated
kind: source
mapping_digest: 05e1761038133f69f40af77d180940fa94168af5fea92478049f84f74b8e9d48
path: nix/verification/tests/catalog.nix
reviewed_chapters:
  marshall/priv/hldd/07-guests.md: 0f73d65e0218aa15612a351af492879d87f78f6e864901c932124fc394334f4e
  marshall/priv/hldd/12-configuration.md: 5318d494cf8479636aa2e2c3c61cb5505cb4cb8386e39b935cf62c62b997169f
  marshall/priv/hldd/13-deployment.md: 0bc4fe19bb9cdf60d5edc24c3777c7f54b170426d9ae5d1f611a2240053c3350
  marshall/priv/hldd/14-operations.md: 68c72d0e6fde22edd5d892f824dedd44f1843d68ece6c96ff5b3e2c1e50051c9
  marshall/priv/hldd/15-monitoring.md: db740282f22afc4c76be24d9db3f9ef4f10bf2745089a754647c6cf7e8fdfeef
  marshall/priv/hldd/16-recovery.md: 194fe77196ac4a25ab764d5cf4aee7558da547cd7b59726f32a302019b26136c
  marshall/priv/hldd/17-reference.md: f1763e53aa081b752df936173e2041b4cda3351ada40a096cc2eac99b020c4da
  marshall/priv/hldd/18-options.md: b77705d41af60b439aef285e8570cf22e86c2f3dbf252496cef9896d916751b2
  marshall/priv/hldd/19-coverage.md: 347130fc1c617f8d232fc8b20221c6f5a2111e5e05a7fcc9b2d0f286081c4cc9
  marshall/priv/hldd/20-security.md: cf1337ba6e78c460d2d00a269abbe3ad011151401179263eb51ab2d90bb4948f
  marshall/priv/hldd/21-domains.md: 64cf0af44004d07c4e5c3402225bb22e5f4f29ae1e8a15b5c7690de8b769efb7
  marshall/priv/hldd/22-topology.md: b66172c618dc03b360046d5e1a6f2850265e5eb7acbe02e20c068a0efdf1569f
state: present
version: 2
---

Marshall gains the artifactContentHost option and per-instance artifactPort listener; HAProxy adds a separate content-host frontend that strips Cookie, Authorization and Proxy-Authorization, deletes backend Set-Cookie, admits only GET and HEAD and answers 421 across hosts, and ACME issues and publishes the second name; release Oban queues include agent_tools and artifacts. The new artifact-origin, artifact-agent-publish and thread-tool machine tests and their fleet fixtures (server-tool operator, provider scripts, thread seeding through a genuine machine binding, current executor capability lists) are catalogued. Chapters 12-configuration, 13-deployment, 14-operations, 16-recovery, 18-options, 19-coverage, 20-security and 22-topology describe the options, rollout, jobs, recovery, proxy lockdown and recorded local machine passes.
