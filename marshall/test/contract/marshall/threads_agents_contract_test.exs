defmodule MarshallThreadsAgentsContractTest do
  use Covenant.Case, component: "marshall.threads_agents"

  @tag obligation: "marshall.threads_agents.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Marshall.Agents,
      Marshall.Agents.AuditEvent,
      Marshall.Agents.CLIAccess,
      Marshall.Agents.CLISession,
      Marshall.Agents.Capabilities,
      Marshall.Agents.Command,
      Marshall.Agents.Compaction,
      Marshall.Agents.Context,
      Marshall.Agents.ContextCheckpoint,
      Marshall.Agents.ContextManifest,
      Marshall.Agents.ContextPolicy,
      Marshall.Agents.ContextSnapshot,
      Marshall.Agents.Conversation,
      Marshall.Agents.Event,
      Marshall.Agents.EventActivity,
      Marshall.Agents.Executor,
      Marshall.Agents.ExecutorRPC,
      Marshall.Agents.ExecutorSession,
      Marshall.Agents.Loop,
      Marshall.Agents.ModelCall,
      Marshall.Agents.ModelCalls,
      Marshall.Agents.ModelProtocol,
      Marshall.Agents.PlanProposal,
      Marshall.Agents.Planning,
      Marshall.Agents.PlanningQuestion,
      Marshall.Agents.Prompt,
      Marshall.Agents.Registration,
      Marshall.Agents.Root,
      Marshall.Agents.SearchCache,
      Marshall.Agents.SearchUsage,
      Marshall.Agents.SkillInstallation,
      Marshall.Agents.SkillMaintenance,
      Marshall.Agents.SkillOperation,
      Marshall.Agents.SkillRevision,
      Marshall.Agents.Skills,
      Marshall.Agents.Skills.Catalog,
      Marshall.Agents.Skills.Failures,
      Marshall.Agents.Thread,
      Marshall.Agents.Turn,
      Marshall.Agents.TurnCoordinator,
      Marshall.Agents.WebSearch,
      Marshall.Threads,
      Marshall.Threads.AccessChange,
      Marshall.Threads.Activity,
      Marshall.Threads.ArchiveWorker,
      Marshall.Threads.Authorization,
      Marshall.Threads.Controls,
      Marshall.Threads.Coordinator,
      Marshall.Threads.Generation,
      Marshall.Threads.Grant,
      Marshall.Threads.MachineSpec,
      Marshall.Threads.Mode,
      Marshall.Threads.ProvisionWorker,
      Marshall.Threads.Sharing,
      Marshall.Threads.Thread,
      Marshall.Threads.Title,
      Marshall.Threads.TitleWorker,
      Marshall.Threads.TouchActivity
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end

  @tag obligation: "marshall.threads_agents.I2"
  test "accepts only registered thread commands and modes" do
    assert MarshallWeb.ThreadCommands.parse("/plan next") == {:command, :plan, "next"}
    assert MarshallWeb.ThreadCommands.parse("/terminal now") == {:error, :command_arguments}
    assert MarshallWeb.ThreadCommands.parse(" /plan") == {:prompt, " /plan"}
    assert Marshall.Threads.Mode.parse("high") == {:ok, :high}
    assert Marshall.Threads.Mode.parse("invalid") == {:error, :invalid_mode}
  end

  @tag obligation: "marshall.threads_agents.I3"
  test "keeps executor capabilities finite" do
    assert Marshall.Agents.ExecutorSession.valid_capabilities?(["context-v1", "skills-v1"])
    refute Marshall.Agents.ExecutorSession.valid_capabilities?(["context-v1", "context-v1"])
    refute Marshall.Agents.ExecutorSession.valid_capabilities?(["unknown"])

    refute Marshall.Agents.ExecutorSession.supported?(
             %Marshall.Agents.Executor{capabilities: []},
             :context_inventory
           )

    assert Marshall.Agents.ExecutorSession.supported?(
             %Marshall.Agents.Executor{capabilities: []},
             :exec_command
           )
  end

  @tag obligation: "marshall.threads_agents.I4"
  test "planning questions reject duplicates and out of bounds input" do
    question = %{
      "id" => "q1",
      "header" => "Choose",
      "question" => "Which?",
      "options" => [
        %{"label" => "A", "description" => "first"},
        %{"label" => "B", "description" => "second"}
      ]
    }

    assert {:ok, [^question]} = Marshall.Agents.Planning.validate_questions([question])

    assert {:error, :invalid_questions} =
             Marshall.Agents.Planning.validate_questions([question, question])

    assert {:error, :invalid_questions} = Marshall.Agents.Planning.validate_questions([])

    assert {:error, :invalid_questions} =
             Marshall.Agents.Planning.validate_questions(List.duplicate(question, 4))
  end
end
