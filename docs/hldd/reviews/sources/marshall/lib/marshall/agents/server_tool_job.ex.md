---
digest: c512e95cf414e60b6af48341ccdf16dd4aaf112cdc428fb38dda03f10ebd5a74
disposition: updated
kind: source
mapping_digest: c5d6b9e33b777c90bbc22e5608c825ce6977ecc6384e262a6c79b99b4af3d9a2
path: marshall/lib/marshall/agents/server_tool_job.ex
reviewed_chapters:
  marshall/priv/hldd/02-control-plane.md: 8398bc3791875b6bc8cf22b6602a6efccb886c001a0f78d5a1500a3f5707ff3d
  marshall/priv/hldd/03-access.md: 9637f378d65cb4e5cd6ca8b852818cbad487a9a6d008a61ede50e7655fbd6669
  marshall/priv/hldd/04-lifecycle.md: f3c40798f402b553640bb25852bcb205c327c87d7ad6735b4f1b243c5616b4a2
  marshall/priv/hldd/06-workflows.md: e1ad826a83ee16829cca5e5ce4b6d53490e3887e52799bc184bf5096a74e7bfb
  marshall/priv/hldd/08-interactive.md: 368f33fbb31c849c8558e3988b6199db2635f59e76065042873e1de42c9eaef3
  marshall/priv/hldd/11-agents.md: 7d24214acefb26fbd3b08ce582578fd007e6ffa4bd55d986293050de8605356d
  marshall/priv/hldd/15-monitoring.md: db740282f22afc4c76be24d9db3f9ef4f10bf2745089a754647c6cf7e8fdfeef
  marshall/priv/hldd/17-reference.md: f1763e53aa081b752df936173e2041b4cda3351ada40a096cc2eac99b020c4da
  marshall/priv/hldd/19-coverage.md: 347130fc1c617f8d232fc8b20221c6f5a2111e5e05a7fcc9b2d0f286081c4cc9
  marshall/priv/hldd/20-security.md: cf1337ba6e78c460d2d00a269abbe3ad011151401179263eb51ab2d90bb4948f
  marshall/priv/hldd/21-domains.md: 64cf0af44004d07c4e5c3402225bb22e5f4f29ae1e8a15b5c7690de8b769efb7
  marshall/priv/hldd/22-topology.md: b66172c618dc03b360046d5e1a6f2850265e5eb7acbe02e20c068a0efdf1569f
state: present
version: 2
---

Marshall adds the Artifacts Ash domain (artifact, version, file, blob chunk, grant, access change, storage, view ticket and publish request resources; state machines for artifact, ticket and publish request; Cedar owner/writer/viewer and elevated-admin delete; same-transaction audit; purge, sweep, expiry and usage Oban jobs), the session-free ArtifactContentEndpoint with exact lockdown headers and ticketed fetches, /artifacts and /admin/artifacts LiveViews with a postMessage storage bridge and artifacts Gettext catalogs, and the artifact server tool with guest staging over the artifact_chunk RPC. Thread status becomes an AshStateMachine with one lifecycle event per transition and a status check constraint; ServerToolJob replaces the polling ThreadToolWorker for ADR-0252 thread and message_board commands through ThreadToolDispatch, a reconciler re-enqueues lost jobs, and executor claims exclude Marshall-owned tools. Chapters 03-access, 04-lifecycle, 05-storage, 06-workflows, 11-agents, 15-monitoring, 17-reference, 19-coverage, 20-security, 21-domains and 22-topology and the agents, artifacts-publish-share and thread-tool scenarios describe the behaviour, boundaries, refusals and evidence.
