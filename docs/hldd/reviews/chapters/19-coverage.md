---
digest: 3013a16fd909d453f4c177ed004f5cbc0c52beab7ba86c0c2ab9a6b66cc838f8
disposition: updated
kind: chapter
mapping_digest: null
path: marshall/priv/hldd/19-coverage.md
reviewed_chapters: {}
state: present
version: 2
---

Browser machine creation now hands admission to the setup thread: the machines LiveView tests follow the provisioning receipt and run the durable Threads.ProvisionWorker to admit the VM (or record the thread failure for an undersized request). The default-OSS-creation scenario scope and the generated coverage chapter now name the receipt and worker-based admission; no product behavior changed.
