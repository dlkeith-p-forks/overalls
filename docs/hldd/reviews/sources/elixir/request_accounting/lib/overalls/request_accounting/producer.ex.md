---
digest: 65aeb10f3e019245b1da6c3e87b5936e003d4098fb9e2a25c00897f9fcf85661
disposition: updated
kind: source
mapping_digest: 2272062390f820f27790d68b944163b5a8c4aa097bb58fe18257524d8b10bbd0
path: elixir/request_accounting/lib/overalls/request_accounting/producer.ex
reviewed_chapters:
  marshall/priv/hldd/01-system.md: e746f0ac6783bb5037c9fd2785c8d8b6aee0f5b279cd263d673ad95462566aa2
  marshall/priv/hldd/17-reference.md: 9b7c3c0ba2c93d62cda3b8c5b3914af2ebbab0f7f9c1e6345bdb926d15c8e8cb
  marshall/priv/hldd/21-domains.md: 64cf0af44004d07c4e5c3402225bb22e5f4f29ae1e8a15b5c7690de8b769efb7
  marshall/priv/hldd/22-topology.md: b66172c618dc03b360046d5e1a6f2850265e5eb7acbe02e20c068a0efdf1569f
state: present
version: 2
---

request_accounting from_environment/children accept a validated suffix so one unit hosts two recorders; 17-reference documents it (ADR-0258).
