---
digest: 27ad30c94a7eb625e41a06503e7ab3ab8f28cd815fd0adbf0347f7a70c951c85
disposition: no-impact
kind: source
mapping_digest: 7f8defe6ddb2c25e6497006dc0096f15a491c6b938a993419fabd8af89498825
path: mila/native/android/app/src/main/java/dev/overalls/mila/nativeui/MilaSessionMaterial.kt
reviewed_chapters:
  marshall/priv/hldd/08-interactive.md: 368f33fbb31c849c8558e3988b6199db2635f59e76065042873e1de42c9eaef3
  marshall/priv/hldd/09-network.md: 225196b393bb0b27d8bdc3bac0a787b869f7d22e9d48ed72dc67ccec6d9ae79b
  marshall/priv/hldd/19-coverage.md: 3013a16fd909d453f4c177ed004f5cbc0c52beab7ba86c0c2ab9a6b66cc838f8
  marshall/priv/hldd/20-security.md: 6f505682683ace1b4b948ed6df21f924df87fd5a71793a725906722e7601a211
  marshall/priv/hldd/21-domains.md: 64cf0af44004d07c4e5c3402225bb22e5f4f29ae1e8a15b5c7690de8b769efb7
  marshall/priv/hldd/22-topology.md: b66172c618dc03b360046d5e1a6f2850265e5eb7acbe02e20c068a0efdf1569f
state: present
version: 2
---

Reviewed Android trust reader correction: fixed 8193-byte buffer rejects assets exceeding the existing 8192-byte limit before key access; cancellation propagates. Preserves documented strict trust policy and existing native verification gaps; no new deployment or authority behavior.
