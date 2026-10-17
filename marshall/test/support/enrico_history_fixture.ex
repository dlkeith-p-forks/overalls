defmodule Marshall.EnricoHistoryFixture do
  @moduledoc "Disposable catalog fixtures and a controlled HTTPS attempt endpoint."
  @behaviour Plug
  alias Marshall.Accounts.{Security, User}
  alias Marshall.Compute.Ledger
  alias Marshall.Enrico.{AuditEvent, Catalog, Repository}
  import Plug.Conn

  @type snapshot :: %{repositories: [Repository.t()], events: [AuditEvent.t()]}
  @type responder :: {pid(), reference()}
  @type status :: String.t() | %{state: String.t(), head: String.t()}
  @type outcome ::
          {:ok, term()} | {:raised, :error | :exit | :throw, term(), Exception.stacktrace()}

  # @cc [owner:ghuntley,label:verification] enrico-remote-completion-receipt
  # Only this peer-side envelope proves the remote call completed, including an
  # exception. A transport timeout MUST NOT be confused with remote completion.
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

  # @cc [owner:ghuntley,label:verification] enrico-request-bound-fixture-response
  # Delayed cleanup replies MUST carry the exact request reference, preventing
  # a reused keepalive connection process from consuming an older request's data.
  @spec complete(responder(), status()) :: :ok
  def complete({pid, reference}, status) do
    send(pid, {:complete, reference, status})
    :ok
  end

  @impl true
  @spec init(Plug.opts()) :: Plug.opts()
  def init(opts), do: opts

  @impl true
  @spec call(Plug.Conn.t(), Plug.opts()) :: Plug.Conn.t()
  def call(
        %Plug.Conn{method: "GET", path_info: ["v1", "repos", id, "attempts", attempt]} = conn,
        opts
      ) do
    reference = make_ref()
    send(Keyword.fetch!(opts, :owner), {:attempt_waiting, {self(), reference}, id, attempt})

    receive do
      {:complete, ^reference, status} -> respond(conn, 200, %{status: status})
    after
      25_000 -> respond(conn, 503, %{error: "fixture_timeout"})
    end
  end

  def call(%Plug.Conn{method: "POST"} = conn, _opts),
    do: respond(conn, 202, %{status: "running"})

  def call(%Plug.Conn{method: "DELETE"} = conn, _opts), do: respond(conn, 200, %{removed: true})
  def call(conn, _opts), do: respond(conn, 404, %{error: "not_found"})

  @spec respond(Plug.Conn.t(), pos_integer(), map()) :: Plug.Conn.t()
  defp respond(conn, code, body),
    do: conn |> put_resp_content_type("application/json") |> send_resp(code, JSON.encode!(body))

  @spec snapshot(String.t()) :: snapshot()
  def snapshot(id),
    do: %{
      repositories: Ledger.read!(Repository, id: id),
      events: Ledger.read!(AuditEvent, repository_id: id)
    }

  @spec demote(User.t(), User.t()) :: {:ok, map()} | {:error, term()}
  def demote(actor, target) do
    User
    |> Ash.ActionInput.for_action(:set_administrator, %{user_id: target.id, administrator: false},
      actor: actor
    )
    |> Ash.run_action()
  end

  @spec current_admin?(String.t()) :: boolean()
  def current_admin?(id), do: Security.current(id).administrator

  @spec register(User.t(), String.t()) :: {:ok, Repository.t()} | {:error, term()}
  def register(actor, name), do: Catalog.register(actor, "fixture", name)

  # @cc [owner:ghuntley,label:verification] enrico-real-write-gate
  # The disposable trigger MUST pause only this actor's real catalog insertion
  # or administrator-role update;
  # it MUST NOT acquire authorization locks on behalf of the tested mutation.
  @spec install_gate(String.t(), pos_integer(), :registration | :demotion) :: :ok
  def install_gate(id, gate, kind \\ :registration) do
    id = Ecto.UUID.cast!(id)
    name = gate_name(id)

    {table, event, condition} =
      case kind do
        :registration ->
          {"enrico_repositories", "INSERT", "NEW.registered_by_id = TG_ARGV[0]::uuid"}

        :demotion ->
          {"users", "UPDATE OF administrator",
           "NEW.id = TG_ARGV[0]::uuid AND NOT NEW.administrator"}
      end

    query("""
    CREATE FUNCTION #{name}() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
      IF #{condition} THEN
        PERFORM pg_advisory_xact_lock(TG_ARGV[1]::bigint);
      END IF;
      RETURN NEW;
    END; $$
    """)

    query(
      "CREATE TRIGGER #{name} BEFORE #{event} ON #{table} FOR EACH ROW EXECUTE FUNCTION #{name}('#{id}', '#{gate}')"
    )

    :ok
  end

  @spec remove_gate(String.t(), :registration | :demotion) :: :ok
  def remove_gate(id, kind \\ :registration) do
    table = if kind == :registration, do: "enrico_repositories", else: "users"
    query("DROP TRIGGER IF EXISTS #{gate_name(id)} ON #{table}")
    query("DROP FUNCTION IF EXISTS #{gate_name(id)}()")
    :ok
  end

  # @cc [owner:ghuntley,label:verification] enrico-fixture-history-ownership
  # Callers MUST finish or stop all remote operations before disposal. Only jobs
  # matching repositories registered by these owned fixture users and their
  # exact returned job histories may be deleted; unrelated history MUST survive.
  @spec cleanup([User.t()]) :: :ok
  def cleanup(users) do
    for user <- users do
      id = Ecto.UUID.dump!(user.id)

      for repo <- Ledger.read!(Repository, registered_by_id: user.id) do
        Marshall.CommittedFixtureCleanup.jobs!("args->>'id'=$1", [repo.id])

        query("DELETE FROM enrico_audit_events WHERE repository_id=$1", [Ecto.UUID.dump!(repo.id)])

        query("DELETE FROM enrico_repositories WHERE id=$1", [Ecto.UUID.dump!(repo.id)])
      end

      Marshall.PasskeyFixture.cleanup(user)
      query("DELETE FROM account_admin_events WHERE actor_id=$1 OR target_id=$1", [id])
      query("DELETE FROM users WHERE id=$1", [id])
    end

    :ok
  end

  @spec query(String.t(), [term()]) :: Postgrex.Result.t()
  def query(sql, params \\ []),
    do: Ecto.Adapters.SQL.query!(Marshall.Repo, sql, params, log: false)

  @spec gate_name(String.t()) :: String.t()
  defp gate_name(id), do: "enrico_gate_" <> String.replace(Ecto.UUID.cast!(id), "-", "_")
end
