---
digest: ef9e9d8b90c43b6f48de7056c0c480ff5df26817bdb89efcf069be2fd5b9f302
disposition: updated
kind: source
mapping_digest: 05e1761038133f69f40af77d180940fa94168af5fea92478049f84f74b8e9d48
path: nix/verification/tests/machines/fleet/galileo.nix
reviewed_chapters:
  marshall/priv/hldd/07-guests.md: 0f73d65e0218aa15612a351af492879d87f78f6e864901c932124fc394334f4e
  marshall/priv/hldd/12-configuration.md: ff8e45aaf3daef1140ae8d0ff46e7dff0c95781487abc5511a3202ef1dfd2f15
  marshall/priv/hldd/13-deployment.md: 3ce306b6531fe05f5a3e933d032309c997035c6ef6ac6b16d0b7b99738469327
  marshall/priv/hldd/14-operations.md: 4d9a416eb0df32a8281f24db06739142db91b637c4ea9416a9f23de49bf73010
  marshall/priv/hldd/15-monitoring.md: cc17c4c6d32d94c24da6483a8164f374cad31c77d0a477850dc6684625a8cee5
  marshall/priv/hldd/16-recovery.md: c11d719cde9562dea123b9fff7630f8750bbf758b4919880a15715b86263d3db
  marshall/priv/hldd/17-reference.md: 7cbeeb5bb6bbbbc170df005edbd41b0b9ea84cc90b0598b4e99b800aa95475b2
  marshall/priv/hldd/18-options.md: e4159e629673fa07c1348e3c7fc1545c28cf8596e2d0d1313bd363c1ca545f52
  marshall/priv/hldd/19-coverage.md: 4df19acabce66188a13a367acae5fd2d8dabd1c5c952d8d3e1cd1c08b448f15d
  marshall/priv/hldd/20-security.md: 605d8d26ebd074bb9f89c0ed054efe53f562399fcf2497ba401d8ebf2373b7d4
  marshall/priv/hldd/21-domains.md: 68866597842c524f9f563a37b978a4464974ca2b21a486c94f60ecd1edd6b2da
  marshall/priv/hldd/22-topology.md: ac5b8ee15301fa8b20baa8916997f27b5a394695d3093b80cf9ca016e3226631
state: present
version: 2
---

Peach NixOS module delivers PEACH_CREDENTIAL into a 0700 runtime directory, exposes a 0660 peach-proxy socket joined only by Audi and drops the Lilly unit requirement; the Galileo fleet test issues real credentials and reads reflection from a guest over a fixture leaf carrying reflection.internal. Chapters 13 and 20 describe custody and evidence; 18 is regenerated.
