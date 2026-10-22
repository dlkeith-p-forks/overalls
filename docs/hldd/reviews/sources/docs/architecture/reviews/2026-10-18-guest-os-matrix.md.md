---
digest: 5d664a94ce9028e29a34892335e9ad909880aff3337204bab240d0f79ab9e402
disposition: no-impact
kind: source
mapping_digest: f07446cbdc8e81ddaa4a97fd6d9b0bbde96c7b8a70f872c586949a0d4268de43
path: docs/architecture/reviews/2026-10-18-guest-os-matrix.md
reviewed_chapters:
  marshall/priv/hldd/17-reference.md: 7d88fca8dbe56f67c71ea207b0ed860f4cfc005f7cb9f6ccde4ffe4bc718cda5
  marshall/priv/hldd/19-coverage.md: 70b7ad54d6d2322bb2a0038612dbd422bb0021781705c21d34949476931d88ec
  marshall/priv/hldd/20-security.md: cf1337ba6e78c460d2d00a269abbe3ad011151401179263eb51ab2d90bb4948f
  marshall/priv/hldd/21-domains.md: 64cf0af44004d07c4e5c3402225bb22e5f4f29ae1e8a15b5c7690de8b769efb7
  marshall/priv/hldd/22-topology.md: b66172c618dc03b360046d5e1a6f2850265e5eb7acbe02e20c068a0efdf1569f
state: present
version: 2
---

Reviewed the guest OS matrix review update: the intermittent OmniOS executor-withdrawal timeout is explained (illumos SSH login outlasting the five-second probe) and recorded as fixed with repeated passing runs; HLDD documented behaviour is unchanged.
