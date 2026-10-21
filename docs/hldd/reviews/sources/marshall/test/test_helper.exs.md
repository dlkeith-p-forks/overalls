---
digest: 74599446b35d7f3690f9b9783ee1bc031599ed402f438f1989b9bb834884269f
disposition: no-impact
kind: source
mapping_digest: c5d6b9e33b777c90bbc22e5608c825ce6977ecc6384e262a6c79b99b4af3d9a2
path: marshall/test/test_helper.exs
reviewed_chapters:
  marshall/priv/hldd/02-control-plane.md: 8398bc3791875b6bc8cf22b6602a6efccb886c001a0f78d5a1500a3f5707ff3d
  marshall/priv/hldd/03-access.md: 08dc3c53c626ebafffba5f908f09ccd49edd919b7a03a3ef8c12113f5097bd96
  marshall/priv/hldd/04-lifecycle.md: a3c881206a8331e5dbcd995c9762772639a9e28bdc22102c2a2e64bf63aa7449
  marshall/priv/hldd/06-workflows.md: 97fca2ee73a5dc431d8f040eb16468eaf0f28233c146be2b53804063fadb565b
  marshall/priv/hldd/08-interactive.md: 9d53735606120890645c1514b7f93d810ff3030f715dcd9b2f10eed0a277ca1c
  marshall/priv/hldd/11-agents.md: 78a9e5616f5d0ca90abae80524701d54bb7c010e5341a882ee27d18141de8c27
  marshall/priv/hldd/15-monitoring.md: cc17c4c6d32d94c24da6483a8164f374cad31c77d0a477850dc6684625a8cee5
  marshall/priv/hldd/17-reference.md: 7cbeeb5bb6bbbbc170df005edbd41b0b9ea84cc90b0598b4e99b800aa95475b2
  marshall/priv/hldd/19-coverage.md: 4df19acabce66188a13a367acae5fd2d8dabd1c5c952d8d3e1cd1c08b448f15d
  marshall/priv/hldd/20-security.md: 0854fe3e151c56e794a8069bd384bf68bb6d76cd7827abfeed6c3fa28e91c83b
  marshall/priv/hldd/21-domains.md: 587584208f1a71100280b9e438b46416b8b56f0f0af2eda585006ad373ff22dc
  marshall/priv/hldd/22-topology.md: 03993ebc3b0c89183aa3eafd972187e92b346d929a61f22250e9e1b6774e0b4e
state: present
version: 2
---

Marshall test-only Lilly connector fixtures now clear an inherited deployment service UID and its read-once cache, matching Lilly test setup. Isolated native lease reproduction fails with inherited identity and succeeds without it. Production privilege checks and authorization remain unchanged.
