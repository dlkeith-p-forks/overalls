---
digest: a7cf0b6524009cee0e2d511be008940b6b6ecb4b119e87e9710a1f7f01009b0c
disposition: no-impact
kind: source
mapping_digest: f07446cbdc8e81ddaa4a97fd6d9b0bbde96c7b8a70f872c586949a0d4268de43
path: docs/architecture/reviews/2026-10-18-guest-os-matrix.md
reviewed_chapters:
  marshall/priv/hldd/17-reference.md: 7d88fca8dbe56f67c71ea207b0ed860f4cfc005f7cb9f6ccde4ffe4bc718cda5
  marshall/priv/hldd/19-coverage.md: 0cb3df7d454cd48dcb9c1ddea347951c2eb63843284bbc76dc24f01e680faad9
  marshall/priv/hldd/20-security.md: 6f505682683ace1b4b948ed6df21f924df87fd5a71793a725906722e7601a211
  marshall/priv/hldd/21-domains.md: 64cf0af44004d07c4e5c3402225bb22e5f4f29ae1e8a15b5c7690de8b769efb7
  marshall/priv/hldd/22-topology.md: b66172c618dc03b360046d5e1a6f2850265e5eb7acbe02e20c068a0efdf1569f
state: present
version: 2
---

Adds 2026-10-22 OmniOS sweep evidence to the guest OS matrix review: a pre-existing illumos vioif receive stall under Firecracker that fails github-tools-illumos-retained, and an intermittent first-boot stall in native-omnios-power-loss. No behavior, configuration or protocol changes; the HLDD makes no claim that retained GitHub tools on illumos are qualified, so no chapter text changes.
