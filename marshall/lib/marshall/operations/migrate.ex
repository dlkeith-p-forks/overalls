defmodule Marshall.Operations.Migrate do
  @moduledoc "Pre-switch release migration step; serving nodes never migrate on startup."
  @spec run() :: :ok | {:error, :migration_failed}
  def run do
    Application.load(:marshall)
    {:ok, _} = Application.ensure_all_started(:ecto_sql)
    {:ok, _} = Application.ensure_all_started(:postgrex)

    case Ecto.Migrator.with_repo(
           Marshall.Repo,
           fn repo ->
             Ecto.Migrator.run(repo, :up, all: true, log: false)
           end,
           pool_size: 2
         ) do
      {:ok, _, _} -> :ok
      _ -> {:error, :migration_failed}
    end
  rescue
    _ -> {:error, :migration_failed}
  catch
    :exit, _ -> {:error, :migration_failed}
  end

  @spec main() :: no_return()
  def main do
    case run() do
      :ok ->
        IO.puts("Migrations complete")
        System.halt(0)

      _ ->
        IO.puts(:stderr, "Migration failed; inspect protected database diagnostics")
        System.halt(1)
    end
  end
end
