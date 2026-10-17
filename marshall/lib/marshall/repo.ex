defmodule Marshall.Repo do
  use AshPostgres.Repo,
    otp_app: :marshall

  @impl true
  def installed_extensions do
    # Add extensions here, and the migration generator will install them.
    ["ash-functions", "citext"]
  end

  # Don't open unnecessary transactions
  # will default to `false` in 4.0
  @impl true
  def prefer_transaction? do
    false
  end

  @impl true
  def min_pg_version do
    %Version{major: 18, minor: 6, patch: 0}
  end

  # @cc [owner:ghuntley,label:recovery] repo-answers-probe
  # ADR-0140: a failure observed while this probe also fails is inconclusive
  # (a lost or exhausted database), never evidence of refusal or absence.
  @doc "Whether the database answers a trivial query from this node right now."
  @spec answers?() :: boolean()
  def answers? do
    match?(
      {:ok, _},
      Ecto.Adapters.SQL.query(__MODULE__, "SELECT 1", [], log: false, timeout: 1_000)
    )
  rescue
    # OwnershipError only arises without a sandbox checkout (tests).
    _ in [DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error] -> false
  catch
    # A checkout can also exit (an exited pool or sandbox owner).
    :exit, _ -> false
  end
end
