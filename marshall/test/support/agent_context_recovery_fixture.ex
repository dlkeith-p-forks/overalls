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

  @spec unwrap!({:ok, term()} | {:error, term()}) :: term()
  defp unwrap!({:ok, value}), do: value

  defp unwrap!({:error, reason}),
    do: raise("remote recovery operation failed: #{inspect(reason)}")
end
