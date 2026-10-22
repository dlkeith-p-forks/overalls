---
digest: b53276f54498f382b0d433533b3c46975eecc10068e61ca65c94e72402ee1e14
disposition: updated
kind: source
mapping_digest: f07446cbdc8e81ddaa4a97fd6d9b0bbde96c7b8a70f872c586949a0d4268de43
path: .agents/skills/localization/SKILL.md
reviewed_chapters:
  marshall/priv/hldd/17-reference.md: f1763e53aa081b752df936173e2041b4cda3351ada40a096cc2eac99b020c4da
  marshall/priv/hldd/19-coverage.md: 347130fc1c617f8d232fc8b20221c6f5a2111e5e05a7fcc9b2d0f286081c4cc9
  marshall/priv/hldd/20-security.md: cf1337ba6e78c460d2d00a269abbe3ad011151401179263eb51ab2d90bb4948f
  marshall/priv/hldd/21-domains.md: 64cf0af44004d07c4e5c3402225bb22e5f4f29ae1e8a15b5c7690de8b769efb7
  marshall/priv/hldd/22-topology.md: b66172c618dc03b360046d5e1a6f2850265e5eb7acbe02e20c068a0efdf1569f
state: present
version: 2
---

Accepted ADR-0253 (Artifacts domain), ADR-0254 (isolated artifact content origin) and ADR-0255 (Thread lifecycle state machine and Oban server-tool dispatch around ADR-0252) are indexed and summarized in the architecture overview; the artifacts and thread-tool review records the ADR-0252 merge, validation and remaining gaps; the localization skill lists the artifacts Gettext domain; the logging gate exempts the pure Artifacts.Limits constants and Artifacts.Tool request mapping, whose outcomes are emitted by the publisher and server-tool job. Chapters 17-reference, 19-coverage, 21-domains and 22-topology reference these decisions.
