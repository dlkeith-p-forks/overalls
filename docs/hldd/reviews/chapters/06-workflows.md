---
digest: e1ad826a83ee16829cca5e5ce4b6d53490e3887e52799bc184bf5096a74e7bfb
disposition: updated
kind: chapter
mapping_digest: null
path: marshall/priv/hldd/06-workflows.md
reviewed_chapters: {}
state: present
version: 2
---

Marshall adds the Artifacts Ash domain (artifact, version, file, blob chunk, grant, access change, storage, view ticket and publish request resources; state machines for artifact, ticket and publish request; Cedar owner/writer/viewer and elevated-admin delete; same-transaction audit; purge, sweep, expiry and usage Oban jobs), the session-free ArtifactContentEndpoint with exact lockdown headers and ticketed fetches, /artifacts and /admin/artifacts LiveViews with a postMessage storage bridge and artifacts Gettext catalogs, and the artifact server tool with guest staging over the artifact_chunk RPC. Thread status becomes an AshStateMachine with one lifecycle event per transition and a status check constraint; ServerToolJob replaces the polling ThreadToolWorker for ADR-0252 thread and message_board commands through ThreadToolDispatch, a reconciler re-enqueues lost jobs, and executor claims exclude Marshall-owned tools. Chapters 03-access, 04-lifecycle, 05-storage, 06-workflows, 11-agents, 15-monitoring, 17-reference, 19-coverage, 20-security, 21-domains and 22-topology and the agents, artifacts-publish-share and thread-tool scenarios describe the behaviour, boundaries, refusals and evidence.
