defmodule Marshall.AgentContextRecoveryFixture do
  @moduledoc "Remote durable context, planning and managed-skill operations for recovery tests."

  alias Marshall.Agents.{
    Context,
    ContextCheckpoint,
    Planning,
    PlanningQuestion,
    Skills,
    Thread,
    Turn
  }

  alias Marshall.Compute.Ledger
  alias Marshall.CommittedFixtureCleanup, as: Cleanup
  alias Marshall.Repo

  @type question_call :: %{required(:id) => String.t(), required(:arguments) => map()}

  @type outcome ::
          {:ok, term()}
          | {:error, term()}
          | {:raised, :error | :exit | :throw, term(), Exception.stacktrace()}

  @spec invoke(module(), atom(), [term()]) :: {:completed, outcome()}
  def invoke(module, function, arguments) do
    outcome =
      try do
        apply(module, function, arguments)
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      else
        {:ok, value} -> {:ok, value}
        {:error, reason} -> {:error, reason}
        value -> {:ok, value}
      end

    {:completed, outcome}
  end

  @spec request_questions(String.t(), String.t(), question_call()) :: PlanningQuestion.t()
  def request_questions(thread_id, turn_id, call) do
    Ledger.transaction(fn ->
      thread = Ledger.lock!(Thread, thread_id)
      turn = Ledger.lock!(Turn, turn_id)
      Planning.request_questions_locked!(thread, turn, call)
    end)
    |> unwrap!()
  end

  @spec install_checkpoint(String.t()) :: ContextCheckpoint.t()
  def install_checkpoint(turn_id) do
    Ledger.transaction(fn ->
      turn = Ledger.lock!(Turn, turn_id)
      thread = Ledger.lock!(Thread, turn.thread_id)
      snapshot = Context.snapshot(turn.id)
      frontier = Context.frontier(thread, turn)

      Context.install_checkpoint!(turn, snapshot, %{
        expected_generation: 0,
        frontier: frontier,
        state: %{"summary" => "Recovered compacted context"},
        retained_input: [],
        source_digest: :crypto.hash(:sha256, "recovery-checkpoint") |> Base.encode16(case: :lower)
      })
    end)
    |> unwrap!()
  end

  @spec project(String.t(), String.t()) :: {:ok, Context.projection()} | {:error, atom()}
  def project(thread_id, turn_id) do
    [thread] = Ledger.read!(Thread, id: thread_id)
    [turn] = Ledger.read!(Turn, id: turn_id)
    Context.project(thread, turn)
  end

  @spec install_skill(map(), Marshall.Accounts.User.t()) :: Marshall.Agents.SkillOperation.t()
  def install_skill(arguments, actor) do
    {:ok, operation} = Skills.install(arguments, actor: actor)
    operation
  end

  @spec dispatch_skill(String.t()) :: Marshall.Agents.SkillOperation.t()
  def dispatch_skill(operation_id) do
    {:ok, operation} =
      Skills.dispatch(operation_id, fn _thread, _operation, _request -> Ash.UUID.generate() end)

    operation
  end

  @spec complete_skill(String.t(), map()) :: Marshall.Agents.SkillOperation.t()
  def complete_skill(operation_id, result) do
    {:ok, operation} = Skills.complete(operation_id, result)
    operation
  end

  # @cc [owner:ghuntley,label:verification] agent-context-recovery-owned-cleanup
  # After every remote process has stopped, teardown MUST remove only the
  # captured VM/host and its agent and activity-thread histories and captured
  # users. Context, planning and skill records MUST be removed before their
  # threads; unrelated and detached historical records MUST remain intact.
  # All fixture SQL values MUST use bound parameters inside one transaction.
  @spec cleanup!(String.t(), String.t(), nonempty_list(Marshall.Accounts.User.t())) :: :ok
  def cleanup!(vm_id, host_id, [owner | _] = users) do
    vm = Ecto.UUID.dump!(vm_id)
    host = Ecto.UUID.dump!(host_id)
    user_ids = Enum.map(users, &Ecto.UUID.dump!(&1.id))

    {:ok, :ok} =
      Repo.transaction(fn ->
        %{rows: [[^host]]} =
          query(
            "SELECT p.host_id FROM compute_virtual_machines v JOIN compute_workload_placements p ON p.id=v.current_placement_id WHERE v.id=$1",
            [vm]
          )

        %{rows: [[^vm]]} =
          query("SELECT DISTINCT vm_id FROM compute_workload_placements WHERE host_id=$1", [host])

        %{rows: roots} = query("SELECT id FROM agent_roots WHERE vm_id=$1", [vm])
        roots = Enum.map(roots, fn [id] -> id end)

        %{rows: agent_threads} =
          query("SELECT id FROM agent_threads WHERE root_id=ANY($1::uuid[])", [roots])

        agent_threads = Enum.map(agent_threads, fn [id] -> id end)
        %{rows: activity_threads} = query("SELECT id FROM threads WHERE machine_id=$1", [vm])
        activity_threads = Enum.map(activity_threads, fn [id] -> id end)
        threads = agent_threads ++ activity_threads

        query(
          "DELETE FROM agent_skill_revisions WHERE installation_id IN (SELECT id FROM agent_skill_installations WHERE thread_id=ANY($1::uuid[]))",
          [threads]
        )

        for table <- [
              "agent_context_checkpoints",
              "agent_context_snapshots",
              "agent_plan_proposals",
              "agent_planning_questions",
              "agent_skill_operations",
              "agent_skill_installations",
              "agent_commands",
              "agent_model_calls",
              "agent_events",
              "agent_turns"
            ] do
          query("DELETE FROM #{table} WHERE thread_id=ANY($1::uuid[])", [threads])
        end

        for table <- ["thread_generations", "thread_access_changes"] do
          query("DELETE FROM #{table} WHERE thread_id=ANY($1::uuid[])", [activity_threads])
        end

        query(
          "DELETE FROM thread_grants_versions WHERE version_source_id IN (SELECT id FROM thread_grants WHERE thread_id=ANY($1::uuid[]))",
          [activity_threads]
        )

        query("DELETE FROM thread_grants WHERE thread_id=ANY($1::uuid[])", [activity_threads])

        query("DELETE FROM threads_versions WHERE version_source_id=ANY($1::uuid[])", [
          activity_threads
        ])

        query("DELETE FROM threads WHERE id=ANY($1::uuid[])", [activity_threads])
        query("DELETE FROM agent_executors WHERE vm_id=$1", [vm])
        query("DELETE FROM agent_cli_sessions WHERE vm_id=$1", [vm])

        query(
          "DELETE FROM inference_credentials_versions WHERE version_source_id IN (SELECT id FROM inference_credentials WHERE host_id=$1)",
          [host]
        )

        query("DELETE FROM inference_credentials WHERE host_id=$1", [host])
        query("UPDATE compute_operations SET completion_outcome_id=NULL WHERE vm_id=$1", [vm])

        query(
          "DELETE FROM account_guest_accounts_versions WHERE version_source_id IN (SELECT id FROM account_guest_accounts WHERE user_id=ANY($1::uuid[]))",
          [user_ids]
        )

        query("DELETE FROM account_guest_accounts WHERE user_id=ANY($1::uuid[])", [user_ids])
        {:ok, _} = Cleanup.cleanup_compute(host_id, owner.id)
        Marshall.AdminAccountFixture.cleanup(users)
        :ok
      end)

    :ok
  end

  @spec query(String.t(), [term()]) :: Postgrex.Result.t()
  defp query(sql, params), do: Repo.query!(sql, params, log: false)

  @spec unwrap!({:ok, term()} | {:error, term()}) :: term()
  defp unwrap!({:ok, value}), do: value

  defp unwrap!({:error, reason}),
    do: raise("remote recovery operation failed: #{inspect(reason)}")
end
