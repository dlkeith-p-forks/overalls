---
digest: 68c72d0e6fde22edd5d892f824dedd44f1843d68ece6c96ff5b3e2c1e50051c9
disposition: updated
kind: chapter
mapping_digest: null
path: marshall/priv/hldd/14-operations.md
reviewed_chapters: {}
state: present
version: 2
---

Marshall gains the artifactContentHost option and per-instance artifactPort listener; HAProxy adds a separate content-host frontend that strips Cookie, Authorization and Proxy-Authorization, deletes backend Set-Cookie, admits only GET and HEAD and answers 421 across hosts, and ACME issues and publishes the second name; release Oban queues include agent_tools and artifacts. The new artifact-origin, artifact-agent-publish and thread-tool machine tests and their fleet fixtures (server-tool operator, provider scripts, thread seeding through a genuine machine binding, current executor capability lists) are catalogued. Chapters 12-configuration, 13-deployment, 14-operations, 16-recovery, 18-options, 19-coverage, 20-security and 22-topology describe the options, rollout, jobs, recovery, proxy lockdown and recorded local machine passes.
