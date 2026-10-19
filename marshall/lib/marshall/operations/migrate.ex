defmodule Marshall.Operations.Migrate do
  @moduledoc "Pre-switch release migration step; serving nodes never migrate on startup."
  require Marshall.Events

  @postgres_codes [
    :duplicate_table,
    :duplicate_column,
    :undefined_table,
    :undefined_column,
    :invalid_schema_name,
    :invalid_catalog_name,
    :invalid_password,
    :invalid_authorization_specification,
    :insufficient_privilege,
    :too_many_connections,
    :cannot_connect_now,
    :connection_failure,
    :query_canceled,
    :lock_not_available,
    :deadlock_detected,
    :serialization_failure,
    :disk_full,
    :out_of_memory,
    :admin_shutdown
  ]

  @type exception_class ::
          :postgrex
          | :connection
          | :migration
          | :match
          | :argument
          | :runtime
          | :unknown
          | :exit
          | :unexpected_result
  @type postgres_code ::
          :unknown
          | :duplicate_table
          | :duplicate_column
          | :undefined_table
          | :undefined_column
          | :invalid_schema_name
          | :invalid_catalog_name
          | :invalid_password
          | :invalid_authorization_specification
          | :insufficient_privilege
          | :too_many_connections
          | :cannot_connect_now
          | :connection_failure
          | :query_canceled
          | :lock_not_available
          | :deadlock_detected
          | :serialization_failure
          | :disk_full
          | :out_of_memory
          | :admin_shutdown
  @type diagnostic :: %{exception_class: exception_class(), postgres_code: postgres_code()}
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
      {:error, error} -> failed(failure_diagnostic(error))
      _ -> failed(%{exception_class: :unexpected_result, postgres_code: :unknown})
    end
  rescue
    error -> failed(failure_diagnostic(error))
  catch
    :exit, _ -> failed(%{exception_class: :exit, postgres_code: :unknown})
  end

  # @cc [owner:ghuntley,label:security;observability] migration-failure-closed-diagnostic
  # Failures MUST preserve the existing refusal result and expose only closed
  # exception categories and reviewed PostgreSQL codes through the Events catalog.
  # Exception messages, queries, parameters and connection data MUST never enter
  # diagnostics; unknown and nested reasons MUST remain opaque.
  @doc false
  @spec failure_diagnostic(term()) :: diagnostic()
  def failure_diagnostic(%Postgrex.Error{postgres: postgres}) do
    code = if is_map(postgres), do: Map.get(postgres, :code)

    %{
      exception_class: :postgrex,
      postgres_code: if(code in @postgres_codes, do: code, else: :unknown)
    }
  end

  def failure_diagnostic(%DBConnection.ConnectionError{}),
    do: %{exception_class: :connection, postgres_code: :unknown}

  def failure_diagnostic(%Ecto.MigrationError{}),
    do: %{exception_class: :migration, postgres_code: :unknown}

  def failure_diagnostic(%MatchError{}), do: %{exception_class: :match, postgres_code: :unknown}

  def failure_diagnostic(%ArgumentError{}),
    do: %{exception_class: :argument, postgres_code: :unknown}

  def failure_diagnostic(%RuntimeError{}),
    do: %{exception_class: :runtime, postgres_code: :unknown}

  def failure_diagnostic(_), do: %{exception_class: :unknown, postgres_code: :unknown}

  @spec failed(diagnostic()) :: {:error, :migration_failed}
  defp failed(diagnostic) do
    Marshall.Events.emit("operations.migration_failed",
      exception_class: diagnostic.exception_class,
      postgres_code: diagnostic.postgres_code
    )

    {:error, :migration_failed}
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
