---
digest: 829468c3a6c82f72865ab918f643fd3f7b8b7853296b3a3c8ee963b0cbc6f28b
disposition: no-impact
kind: source
mapping_digest: f07446cbdc8e81ddaa4a97fd6d9b0bbde96c7b8a70f872c586949a0d4268de43
path: scripts/test/check_contracts_test.mjs
reviewed_chapters:
  marshall/priv/hldd/17-reference.md: f873720e39141ec28babf1da9573796b2d87067b2f8779ea16340d22afb90576
  marshall/priv/hldd/19-coverage.md: c976b09479ec9152ca196669500eddbc5814e4d04d35c616d4898aa19e2b0356
  marshall/priv/hldd/20-security.md: ebf5f76bb3b9c45d1bd1dd0c370480f4634f4ad6df267fa706355fb48ed38537
  marshall/priv/hldd/21-domains.md: 4dee7985b92fb3a4f0a28e9f9ca1a905dea34e9a8530fe6c069a9258b475b7c0
  marshall/priv/hldd/22-topology.md: ac5b8ee15301fa8b20baa8916997f27b5a394695d3093b80cf9ca016e3226631
state: present
version: 2
---

Reviewed complete contract inventory discovery through an owned temporary file, including the new greater-than-one-MiB regression. All 21 checker regression tests pass. No change to documented contract semantics or handbook behavior.
