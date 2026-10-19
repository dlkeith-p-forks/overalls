defmodule Susan.Repo do
  @moduledoc "Susan's own PostgreSQL repository; it never shares a database with Marshall."
  use AshPostgres.Repo, otp_app: :susan

  @impl true
  def installed_extensions, do: ["ash-functions"]

  @impl true
  def prefer_transaction?, do: false

  @impl true
  def min_pg_version, do: %Version{major: 16, minor: 0, patch: 0}

  @doc "Whether the database answers a trivial query from this node right now."
  @spec answers?() :: boolean()
  def answers? do
    match?(
      {:ok, _},
      Ecto.Adapters.SQL.query(__MODULE__, "SELECT 1", [], log: false, timeout: 1_000)
    )
  rescue
    _ in [DBConnection.ConnectionError, DBConnection.OwnershipError, Postgrex.Error] -> false
  catch
    :exit, _ -> false
  end
end
