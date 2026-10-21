---
digest: dd4d9550a45e6f413c0c96a4a410f1d55d8496d555d706d9959b69c08e378219
disposition: no-impact
kind: source
mapping_digest: 05e1761038133f69f40af77d180940fa94168af5fea92478049f84f74b8e9d48
path: nix/verification/tests/evaluation/fleet-guest-trust.nix
reviewed_chapters:
  marshall/priv/hldd/07-guests.md: 0f73d65e0218aa15612a351af492879d87f78f6e864901c932124fc394334f4e
  marshall/priv/hldd/12-configuration.md: ff8e45aaf3daef1140ae8d0ff46e7dff0c95781487abc5511a3202ef1dfd2f15
  marshall/priv/hldd/13-deployment.md: c705cfb775b72bcc94c855ba75fc7c6fb67cbff21d554e04648757732250b54a
  marshall/priv/hldd/14-operations.md: 4d9a416eb0df32a8281f24db06739142db91b637c4ea9416a9f23de49bf73010
  marshall/priv/hldd/15-monitoring.md: cc17c4c6d32d94c24da6483a8164f374cad31c77d0a477850dc6684625a8cee5
  marshall/priv/hldd/16-recovery.md: c11d719cde9562dea123b9fff7630f8750bbf758b4919880a15715b86263d3db
  marshall/priv/hldd/17-reference.md: 7cbeeb5bb6bbbbc170df005edbd41b0b9ea84cc90b0598b4e99b800aa95475b2
  marshall/priv/hldd/18-options.md: e4159e629673fa07c1348e3c7fc1545c28cf8596e2d0d1313bd363c1ca545f52
  marshall/priv/hldd/19-coverage.md: 4df19acabce66188a13a367acae5fd2d8dabd1c5c952d8d3e1cd1c08b448f15d
  marshall/priv/hldd/20-security.md: 0854fe3e151c56e794a8069bd384bf68bb6d76cd7827abfeed6c3fa28e91c83b
  marshall/priv/hldd/21-domains.md: 587584208f1a71100280b9e438b46416b8b56f0f0af2eda585006ad373ff22dc
  marshall/priv/hldd/22-topology.md: 03993ebc3b0c89183aa3eafd972187e92b346d929a61f22250e9e1b6774e0b4e
state: present
version: 2
---

Reviewed fleet-race-pool-fits-reservation, image-derived storageGiB and trust assertions. Check identical positive whole-GiB quotas on both hosts and matching driver storage_budget, retain the32GiB clone minimum, and leave image-dependent race headroom enforced by the constructor. The obsolete16GiB exact default is not a current capacity requirement. No runtime capacity, trust, architecture or native claim changes.
