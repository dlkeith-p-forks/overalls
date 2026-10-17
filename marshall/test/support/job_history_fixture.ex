defmodule Marshall.JobHistoryFixture do
  @moduledoc "Disposable raw-job setup and committed write gates; never a production worker."
  import Ecto.Query
  alias Marshall.Accounts.User
  alias Marshall.Administration
  alias Marshall.Compute.Ledger
  alias Marshall.Repo

  @type operation :: :retry | :lock | :signout | :demote | :prune | :complete
  @type outcome ::
          {:ok, term()} | {:raised, :error | :exit | :throw, term(), Exception.stacktrace()}

  # @cc [owner:ghuntley,label:verification] job-history-remote-completion
  # Only a peer-side completion envelope proves a remote mutation stopped. A
  # transport timeout MUST cause peer shutdown before disposable fixture cleanup.
  @spec invoke(module(), atom(), [term()]) :: {:completed, outcome()}
  def invoke(module, function, arguments) do
    outcome =
      try do
        {:ok, apply(module, function, arguments)}
      catch
        kind, reason -> {:raised, kind, reason, __STACKTRACE__}
      end

    {:completed, outcome}
  end

  @type snapshot :: %{
          raw: Oban.Job.t() | nil,
          snapshot: [Administration.JobSnapshot.t()],
          events: [Administration.JobEvent.t()],
          receipts: [Administration.AuditEvent.t()]
        }

  @spec insert(String.t()) :: Oban.Job.t()
  def insert(queue) do
    %{"private" => "job-history-private-fixture"}
    |> Oban.Job.new(worker: "Marshall.JobHistoryFixture", queue: queue, max_attempts: 2)
    |> Oban.insert!()
  end

  @spec transition(pos_integer(), String.t(), non_neg_integer(), non_neg_integer()) :: :ok
  def transition(id, state, attempt, error_count) do
    errors =
      List.duplicate(
        %{"error" => "job-history-private-fixture", "attempt" => attempt},
        error_count
      )

    {1, _} =
      Repo.update_all(from(j in Oban.Job, where: j.id == ^id),
        set: [state: state, attempt: attempt, errors: errors]
      )

    :ok
  end

  @spec role(User.t(), User.t(), boolean()) ::
          {:ok, %{user_id: String.t(), administrator: boolean()}} | {:error, term()}
  def role(operator, target, enabled) do
    User
    |> Ash.ActionInput.for_action(
      :set_administrator,
      %{user_id: target.id, administrator: enabled},
      actor: operator
    )
    |> Ash.run_action()
  end

  @spec act(operation(), pos_integer(), User.t(), User.t(), String.t()) :: term()
  def act(:retry, id, actor, _operator, request),
    do: Administration.retry_job(%{id: id, request_id: request}, actor: actor)

  def act(:lock, _id, actor, _operator, _request),
    do: Marshall.PasskeyFixture.action(actor, :lock)

  def act(:signout, _id, actor, _operator, _request) do
    conn =
      Plug.Test.conn(:get, "/sign-out")
      |> Plug.Test.init_test_session(%{"user_token" => actor.__metadata__.token})
      |> Plug.Conn.assign(:current_user, actor)
      |> Phoenix.Controller.fetch_flash()
      |> MarshallWeb.AuthController.sign_out(%{})

    {:ok, %{status: conn.status}}
  end

  def act(:demote, _id, actor, operator, _request), do: role(operator, actor, false)

  def act(:prune, id, _actor, _operator, _request),
    do: Repo.delete_all(from(j in Oban.Job, where: j.id == ^id))

  def act(:complete, id, _actor, _operator, _request), do: transition(id, "completed", 1, 1)

  @spec snapshot(pos_integer(), String.t()) :: snapshot()
  def snapshot(id, actor_id) do
    %{
      raw: Repo.get(Oban.Job, id),
      snapshot: Ledger.read!(Administration.JobSnapshot, id: id),
      events:
        Ledger.read!(Administration.JobEvent, job_id: id)
        |> Enum.sort_by(& &1.id),
      receipts:
        Ledger.read!(Administration.AuditEvent, actor_id: actor_id)
        |> Enum.sort_by(& &1.id)
    }
  end

  # @cc [owner:ghuntley,label:verification] job-history-production-write-gate
  # Gates MUST pause the selected actual write without supplying authority locks.
  # Raw transitions are fixture fault injection, never evidence of worker execution.
  @spec install_gate(operation(), pos_integer(), String.t(), pos_integer()) :: :ok
  def install_gate(operation, id, actor_id, gate) do
    actor_id = Ecto.UUID.cast!(actor_id)

    {table, event, condition, returned} =
      case operation do
        :retry ->
          {"oban_jobs", "UPDATE", "NEW.id = #{id} AND NEW.state = 'available'", "NEW"}

        :complete ->
          {"oban_jobs", "UPDATE", "NEW.id = #{id} AND NEW.state = 'completed'", "NEW"}

        :prune ->
          {"oban_jobs", "DELETE", "OLD.id = #{id}", "OLD"}

        :lock ->
          {"account_verifications", "UPDATE",
           "NEW.user_id = '#{actor_id}'::uuid AND NEW.elevated_until IS NULL", "NEW"}

        :demote ->
          {"users", "UPDATE", "NEW.id = '#{actor_id}'::uuid AND NOT NEW.administrator", "NEW"}

        :signout ->
          {"tokens", "UPDATE",
           "NEW.subject = 'user?id=#{actor_id}' AND NEW.purpose = 'revocation'", "NEW"}
      end

    query("""
    CREATE FUNCTION #{name(id)}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF #{condition} THEN PERFORM pg_advisory_xact_lock(#{gate}); END IF;
      RETURN #{returned};
    END; $$
    """)

    query(
      "CREATE TRIGGER #{name(id)} BEFORE #{event} ON #{table} FOR EACH ROW EXECUTE FUNCTION #{name(id)}()"
    )

    :ok
  end

  @spec remove_gate(operation(), pos_integer()) :: :ok
  def remove_gate(operation, id) do
    table =
      case operation do
        :lock -> "account_verifications"
        :signout -> "tokens"
        :demote -> "users"
        _ -> "oban_jobs"
      end

    query("DROP TRIGGER IF EXISTS #{name(id)} ON #{table}")
    query("DROP FUNCTION IF EXISTS #{name(id)}()")
    :ok
  end

  @spec cleanup([pos_integer()], [User.t()]) :: :ok
  def cleanup(ids, users) do
    for id <- ids do
      query("DELETE FROM oban_jobs WHERE id=$1", [id])
      query("DELETE FROM admin_job_snapshots WHERE id=$1", [id])
      query("DELETE FROM admin_job_events WHERE job_id=$1", [id])
    end

    for user <- users do
      id = Ecto.UUID.dump!(user.id)
      Marshall.PasskeyFixture.cleanup(user)
      query("DELETE FROM admin_audit_events WHERE actor_id=$1", [id])
      query("DELETE FROM account_admin_events WHERE actor_id=$1 OR target_id=$1", [id])
      query("DELETE FROM users WHERE id=$1", [id])
    end

    :ok
  end

  @spec query(String.t(), [term()]) :: Postgrex.Result.t()
  def query(sql, params \\ []), do: Ecto.Adapters.SQL.query!(Repo, sql, params, log: false)

  @spec name(pos_integer()) :: String.t()
  defp name(id) when is_integer(id) and id > 0, do: "job_history_gate_#{id}"
end
