defmodule Marshall.GitHubDistributedFixture do
  @moduledoc "Committed GitHub fixtures for three-replica authority races; contains synthetic tokens only."
  alias Marshall.Accounts.{Security, User}
  alias Marshall.Compute.Ledger
  alias Marshall.GitHub
  alias Marshall.GitHub.{Connection, RefreshAttempt}
  alias Marshall.CommittedFixtureCleanup, as: Cleanup

  @spec callback(User.t(), binary(), binary(), pid(), reference()) ::
          {:ok, GitHub.status_info()} | {:error, GitHub.error()}
  def callback(actor, jti, state, owner, reference) do
    Process.put(:github_test_gate, {owner, reference})
    GitHub.callback(actor, jti, state, "synthetic-code")
  end

  @spec refresh(binary(), pid(), reference()) ::
          :ok | {:snooze, pos_integer()} | {:error, :unavailable}
  def refresh(id, owner, reference) do
    Process.put(:github_test_gate, {owner, reference})
    GitHub.refresh_connection(id)
  end

  @spec connect(User.t()) :: {:ok, GitHub.status_info()} | {:error, GitHub.error()}
  def connect(actor) do
    {:ok, ceremony} = GitHub.begin_authorization(actor, Security.jti(actor))
    state = URI.decode_query(URI.parse(ceremony.url).query)["state"]
    GitHub.callback(actor, Security.jti(actor), state, "synthetic-code")
  end

  @spec due!(binary()) :: :ok
  def due!(id) do
    Marshall.Repo.query!(
      "UPDATE github_connections SET refresh_due_at=clock_timestamp()-interval '1 second' WHERE id=$1",
      [Ecto.UUID.dump!(id)], log: false)

    :ok
  end

  @spec snapshot(binary()) :: %{connections: [Connection.t()], attempts: [RefreshAttempt.t()]}
  def snapshot(user_id) do
    connections = Ledger.read!(Connection, user_id: user_id)
    attempts = Enum.flat_map(connections, &Ledger.read!(RefreshAttempt, connection_id: &1.id))
    %{connections: connections, attempts: attempts}
  end

  # @cc [owner:ghuntley,label:verification] github-committed-cleanup-exact-owner
  # Cleanup MUST delete only rows identified by this fixture's captured user and
  # connection/attempt IDs, including their ID-only jobs. Unrelated GitHub users,
  # tokens, jobs and audit history MUST survive.
  @spec cleanup!(User.t()) :: :ok
  def cleanup!(user) do
    %{rows: connections} =
      Marshall.Repo.query!(
        "SELECT id FROM github_connections WHERE user_id=$1",
        [Ecto.UUID.dump!(user.id)], log: false)

    connection_ids = Enum.map(connections, fn [id] -> id end)

    %{rows: attempts} =
      Marshall.Repo.query!(
        "SELECT id FROM github_authorization_attempts WHERE connection_id=ANY($1::uuid[])",
        [connection_ids], log: false)

    %{rows: refresh_attempts} =
      Marshall.Repo.query!(
        "SELECT id FROM github_refresh_attempts WHERE connection_id=ANY($1::uuid[])",
        [connection_ids], log: false)

    job_ids =
      Enum.map(
        connection_ids ++ Enum.map(attempts ++ refresh_attempts, fn [id] -> id end),
        &Ecto.UUID.load!/1
      )

    Cleanup.jobs!("args->>'id'=ANY($1::text[])", [job_ids])

    for table <- ["github_audit_events", "github_exclusions"] do
      Marshall.Repo.query!(
        "DELETE FROM " <> table <> " WHERE user_id=$1",
        [Ecto.UUID.dump!(user.id)], log: false)
    end

    for table <- [
          "github_request_leases",
          "github_refresh_attempts",
          "github_authorization_attempts"
        ] do
      Marshall.Repo.query!(
        "DELETE FROM " <> table <> " WHERE connection_id=ANY($1::uuid[])",
        [connection_ids], log: false)
    end

    Marshall.Repo.query!(
      "DELETE FROM github_connections WHERE user_id=$1",
      [Ecto.UUID.dump!(user.id)], log: false)

    Marshall.PasskeyFixture.cleanup(user)
    Marshall.Repo.query!("DELETE FROM users WHERE id=$1", [Ecto.UUID.dump!(user.id)], log: false)
    :ok
  end
end
