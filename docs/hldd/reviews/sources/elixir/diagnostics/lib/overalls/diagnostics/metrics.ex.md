---
digest: 9555fdfcdb66ea8d9082b82a105316ec660efde26b6a631cb2aeb692f5f61188
disposition: updated
kind: source
mapping_digest: 2272062390f820f27790d68b944163b5a8c4aa097bb58fe18257524d8b10bbd0
path: elixir/diagnostics/lib/overalls/diagnostics/metrics.ex
reviewed_chapters:
  marshall/priv/hldd/01-system.md: e746f0ac6783bb5037c9fd2785c8d8b6aee0f5b279cd263d673ad95462566aa2
  marshall/priv/hldd/17-reference.md: f1763e53aa081b752df936173e2041b4cda3351ada40a096cc2eac99b020c4da
  marshall/priv/hldd/21-domains.md: 64cf0af44004d07c4e5c3402225bb22e5f4f29ae1e8a15b5c7690de8b769efb7
  marshall/priv/hldd/22-topology.md: b66172c618dc03b360046d5e1a6f2850265e5eb7acbe02e20c068a0efdf1569f
state: present
version: 2
---

Shared diagnostics gain the marshall.agent.server_tool, marshall.artifact.publish, marshall.artifact.content and marshall.cedar.authorize spans, tool/namespace/via enum and version/file_count number attributes, and the server-tool and artifact publish, refusal, content and storage metrics; the regenerated trace schema matches. Chapters 15-monitoring and 17-reference list these signals and their closed attributes.
