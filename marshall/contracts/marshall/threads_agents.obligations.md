---
modules: [Marshall.Agents, Marshall.Agents.AuditEvent, Marshall.Agents.CLIAccess, Marshall.Agents.CLISession, Marshall.Agents.Capabilities, Marshall.Agents.Command, Marshall.Agents.Compaction, Marshall.Agents.Context, Marshall.Agents.ContextCheckpoint, Marshall.Agents.ContextManifest, Marshall.Agents.ContextPolicy, Marshall.Agents.ContextSnapshot, Marshall.Agents.Conversation, Marshall.Agents.Event, Marshall.Agents.EventActivity, Marshall.Agents.Executor, Marshall.Agents.ExecutorRPC, Marshall.Agents.ExecutorSession, Marshall.Agents.Loop, Marshall.Agents.ModelCall, Marshall.Agents.ModelCalls, Marshall.Agents.ModelProtocol, Marshall.Agents.PlanProposal, Marshall.Agents.Planning, Marshall.Agents.PlanningQuestion, Marshall.Agents.Prompt, Marshall.Agents.Registration, Marshall.Agents.Root, Marshall.Agents.SearchCache, Marshall.Agents.SearchUsage, Marshall.Agents.SkillInstallation, Marshall.Agents.SkillMaintenance, Marshall.Agents.SkillOperation, Marshall.Agents.SkillRevision, Marshall.Agents.Skills, Marshall.Agents.Skills.Catalog, Marshall.Agents.Skills.Failures, Marshall.Agents.Thread, Marshall.Agents.Turn, Marshall.Agents.TurnCoordinator, Marshall.Agents.WebSearch, Marshall.Threads, Marshall.Threads.AccessChange, Marshall.Threads.Activity, Marshall.Threads.ArchiveWorker, Marshall.Threads.Authorization, Marshall.Threads.Controls, Marshall.Threads.Coordinator, Marshall.Threads.Generation, Marshall.Threads.Grant, Marshall.Threads.MachineSpec, Marshall.Threads.Mode, Marshall.Threads.ProvisionWorker, Marshall.Threads.Sharing, Marshall.Threads.Thread, Marshall.Threads.Title, Marshall.Threads.TitleWorker, Marshall.Threads.TouchActivity]
---

# Threads Agents obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### marshall.threads_agents.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active
