---
modules: [Marshall.Agents, Marshall.Agents.AuditEvent, Marshall.Agents.CLIAccess, Marshall.Agents.CLISession, Marshall.Agents.Capabilities, Marshall.Agents.Command, Marshall.Agents.Compaction, Marshall.Agents.Context, Marshall.Agents.ContextCheckpoint, Marshall.Agents.ContextManifest, Marshall.Agents.ContextPolicy, Marshall.Agents.ContextSnapshot, Marshall.Agents.Conversation, Marshall.Agents.Event, Marshall.Agents.EventActivity, Marshall.Agents.Executor, Marshall.Agents.ExecutorRPC, Marshall.Agents.ExecutorSession, Marshall.Agents.Loop, Marshall.Agents.ModelCall, Marshall.Agents.ModelCalls, Marshall.Agents.ModelProtocol, Marshall.Agents.PlanProposal, Marshall.Agents.Planning, Marshall.Agents.PlanningQuestion, Marshall.Agents.Prompt, Marshall.Agents.Registration, Marshall.Agents.Root, Marshall.Agents.SearchCache, Marshall.Agents.SearchUsage, Marshall.Agents.ServerTool, Marshall.Agents.ServerToolJob, Marshall.Agents.ServerToolReconciler, Marshall.Agents.SkillInstallation, Marshall.Agents.SkillMaintenance, Marshall.Agents.SkillOperation, Marshall.Agents.SkillRevision, Marshall.Agents.Skills, Marshall.Agents.Skills.Catalog, Marshall.Agents.Skills.Failures, Marshall.Agents.Thread, Marshall.Agents.ThreadTool, Marshall.Agents.ThreadToolDispatch, Marshall.Agents.Turn, Marshall.Agents.TurnCoordinator, Marshall.Agents.WebSearch, Marshall.Threads, Marshall.Threads.AccessChange, Marshall.Threads.Activity, Marshall.Threads.ArchiveWorker, Marshall.Threads.Authorization, Marshall.Threads.Controls, Marshall.Threads.Coordinator, Marshall.Threads.Generation, Marshall.Threads.Grant, Marshall.Threads.MachineSpec, Marshall.Threads.Mode, Marshall.Threads.ProvisionWorker, Marshall.Threads.Sharing, Marshall.Threads.Thread, Marshall.Threads.Title, Marshall.Threads.TitleWorker, Marshall.Threads.TouchActivity]
---

# Threads Agents obligations

## Purpose

The component's declared Elixir modules remain present, compilable, and owned by this Contract. Behavioral, security, persistence, native, and deployment requirements remain linked through the repository's existing `CONTRACTS` and ADR evidence.

### marshall.threads_agents.I1 — Declared modules remain loadable
- **scope:** the modules listed in this component's `modules` front matter
- **must:** Every declared module MUST compile and remain loadable in the project's test VM; removing or renaming one MUST make this contract test fail.
- **kind:** non-functional
- **status:** active

### marshall.threads_agents.I2 — Thread commands and modes reject invalid input
- **scope:** `MarshallWeb.ThreadCommands` and `Marshall.Threads.Mode`
- **must:** Only registered slash commands and supported modes are accepted; malformed commands and modes MUST be refused deterministically.
- **kind:** security
- **status:** active

### marshall.threads_agents.I3 — Executor capabilities are finite
- **scope:** `Marshall.Agents.ExecutorSession.valid_capabilities?/1` and `supported?/2`
- **must:** Unknown, duplicate, or excessive capabilities and unsupported tools MUST be rejected.
- **kind:** security
- **status:** active

### marshall.threads_agents.I4 — Planning questions are bounded and uniquely identified
- **scope:** `Marshall.Agents.Planning.validate_questions/1`
- **must:** Planning input MUST contain one to three well formed questions with bounded text and unique identifiers; malformed or duplicate entries MUST be rejected deterministically.
- **kind:** security
- **status:** active

### marshall.threads_agents.I5 — Machine specifications fail closed and preserve shape
- **scope:** `Marshall.Threads.MachineSpec.from_map/1`
- **must:** Only x86_64 specs with positive bounded VMShape resources and supported profiles MUST be accepted; customer profiles and malformed UUIDs MUST be refused.
- **kind:** security
- **status:** active

### marshall.threads_agents.I6 — Thread titles remain bounded and deterministic on generator failure
- **scope:** `Marshall.Threads.Title.generate/1` and `fallback/1`
- **must:** Generated titles MUST be whitespace-normalized and capped at 120 bytes; generator failures or blank output MUST use the safe objective fallback.
- **kind:** functional
- **status:** active
