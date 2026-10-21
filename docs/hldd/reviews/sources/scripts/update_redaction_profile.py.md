---
digest: 1971ed9f095401199a4a3a4e5b67d1725f46dbd78d31d21dfb6b227d01985115
disposition: no-impact
kind: source
mapping_digest: f07446cbdc8e81ddaa4a97fd6d9b0bbde96c7b8a70f872c586949a0d4268de43
path: scripts/update_redaction_profile.py
reviewed_chapters:
  marshall/priv/hldd/17-reference.md: 7cbeeb5bb6bbbbc170df005edbd41b0b9ea84cc90b0598b4e99b800aa95475b2
  marshall/priv/hldd/19-coverage.md: 4df19acabce66188a13a367acae5fd2d8dabd1c5c952d8d3e1cd1c08b448f15d
  marshall/priv/hldd/20-security.md: 0854fe3e151c56e794a8069bd384bf68bb6d76cd7827abfeed6c3fa28e91c83b
  marshall/priv/hldd/21-domains.md: 587584208f1a71100280b9e438b46416b8b56f0f0af2eda585006ad373ff22dc
  marshall/priv/hldd/22-topology.md: 03993ebc3b0c89183aa3eafd972187e92b346d929a61f22250e9e1b6774e0b4e
state: present
version: 2
---

Reviewed the redaction profile generator formatting diff against security and reference coverage. Ruff changes whitespace and equivalent string quote spelling only; parsed Python syntax trees are identical. No generated profile, runtime behavior, architecture or verification scope changes.
