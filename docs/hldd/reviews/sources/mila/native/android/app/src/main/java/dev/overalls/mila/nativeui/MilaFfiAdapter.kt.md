---
digest: 6e82652269ac0f7bfffd17f54e7449e4315e4b94f59a4ef238bd9242e5436fca
disposition: updated
kind: source
mapping_digest: 7f8defe6ddb2c25e6497006dc0096f15a491c6b938a993419fabd8af89498825
path: mila/native/android/app/src/main/java/dev/overalls/mila/nativeui/MilaFfiAdapter.kt
reviewed_chapters:
  marshall/priv/hldd/08-interactive.md: 84c255e9addb5a9ef9fbc81ef61b98af77540835332915750a825e39b3c94919
  marshall/priv/hldd/09-network.md: 225196b393bb0b27d8bdc3bac0a787b869f7d22e9d48ed72dc67ccec6d9ae79b
  marshall/priv/hldd/19-coverage.md: 3c428f721611220654bb62ca6bd4251dc29ff549c1ef412f9be98a5e1862a5b3
  marshall/priv/hldd/20-security.md: 6f505682683ace1b4b948ed6df21f924df87fd5a71793a725906722e7601a211
  marshall/priv/hldd/21-domains.md: 64cf0af44004d07c4e5c3402225bb22e5f4f29ae1e8a15b5c7690de8b769efb7
  marshall/priv/hldd/22-topology.md: b66172c618dc03b360046d5e1a6f2850265e5eb7acbe02e20c068a0efdf1569f
state: present
version: 2
---

Android declares POST_NOTIFICATIONS, gates provider registration on OS permission and validates FCM metadata through the Rust FFI without retaining tokens; focused provider tests cover refusal and persistence.
