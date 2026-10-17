defmodule Marshall.Agents do
  @moduledoc "Durable VM-bound agent threads, turns, executor leases and audit receipts."
  use Ash.Domain, otp_app: :marshall, extensions: [AshPaperTrail.Domain]

  paper_trail do
    include_versions? true
  end

  resources do
    resource Marshall.Agents.Root

    resource Marshall.Agents.Thread do
      define :submit_prompt, action: :submit_prompt
    end

    resource Marshall.Agents.Turn
    resource Marshall.Agents.Event
    resource Marshall.Agents.Executor
    resource Marshall.Agents.Command
    resource Marshall.Agents.ModelCall
    resource Marshall.Agents.CLISession
    resource Marshall.Agents.AuditEvent
    resource Marshall.Agents.SearchCache
    resource Marshall.Agents.SearchUsage
    resource Marshall.Agents.ContextSnapshot
    resource Marshall.Agents.ContextCheckpoint
    resource Marshall.Agents.PlanningQuestion
    resource Marshall.Agents.PlanProposal
    resource Marshall.Agents.SkillInstallation
    resource Marshall.Agents.SkillRevision
    resource Marshall.Agents.SkillOperation
  end
end
