---
digest: ebf5f76bb3b9c45d1bd1dd0c370480f4634f4ad6df267fa706355fb48ed38537
disposition: no-impact
kind: chapter
mapping_digest: null
migration:
  deployment:
    chapter_digest: 9a9e9255eb86fa91f3418b1c398853a745a51fd15f2f5eca5737439f6caf08c2
    source_digest: 32939571a328dfb45510183c422eecb46bdb38fa777346f23c0fd9cc2bb9c079
  governance:
    chapter_digest: 751ceb5fdfcc269772d47964ba027021dfc5bbf898375b131030c5c474f3edc0
    source_digest: 9d32ce22ccb4f120978a3e89a9ead131666dc31eab3a6227ca7efab86556993c
  lilly:
    chapter_digest: 985473887db844b21221e9cd15fc4274003de7e7113e496f5a79143075489161
    source_digest: 2b3fed271b8c7d9725d4b0ab37d59c1d7e6d8292013cf4927f5a66f57ebc968c
  marshall:
    chapter_digest: 611713216c60038ac614a76a8aa4c5cb29f705024b6f3d45fb4b34d1ac794463
    source_digest: 66cd97c314ea56b581e84f078c4745e952d0cd805117b65f0d777dadac728694
  mila:
    chapter_digest: e55458d450e8c1eb96b0135d17becedf97db36241e5503077036be57c28ce3f1
    source_digest: 67fa642ad4ad7cbc69bcbfdf12a38549302a7842f95213c629565a0f99bfed28
  protocol:
    chapter_digest: 6ad8755133568a29871821ead8496649cf2eb94dd919470761b790d2b8335ec1
    source_digest: baafb9219dcfb35323e5f8ac2408613cc9637c63de94aa8d58146da77693afa3
  services:
    chapter_digest: 01147e4e7aa57b2b7cd7dc49e393607ec0a4e3a550334d3e00311d6a075eb59b
    source_digest: 16a7457f7a3e51f0d7cbeddb3a83a05890620aab8900bf099a9fb4ac0ce4ab19
path: marshall/priv/hldd/20-security.md
reviewed_chapters: {}
state: present
version: 2
---

marshall: Reviewed concurrent thread-tools and Mila FFI changes; this group’s documented behavior and authority boundaries remain unchanged.

protocol: Reviewed concurrent thread-tools and Mila FFI changes; this group’s documented behavior and authority boundaries remain unchanged.

lilly: Reviewed concurrent thread-tools and Mila FFI changes; this group’s documented behavior and authority boundaries remain unchanged.

services: Reviewed concurrent thread-tools and Mila FFI changes; this group’s documented behavior and authority boundaries remain unchanged.

deployment: Reviewed the Android SDK setup correction; it only makes the native CI job install declared API 36 build inputs and does not alter deployment roles or runtime behavior.

governance: Reviewed the Apple native compile fixes for route hashing and list identity; they preserve the documented native scaffold behavior.

mila: Reviewed the Rust FFI trust-document, push-registration, terminal and watch validation probes; they preserve existing native boundary behavior and do not change handbook deployment, security, or topology contracts.
