defmodule Marshall.Repo.Migrations.DropRetiredDiagnosticTables do
  @moduledoc "ADR-0159 Push 4 (B1): drop diagnostic tables no Ash resource or release maps."
  use Ecto.Migration

  # @cc [owner:ghuntley,label:persistence;recovery] retired-diagnostic-tables-drop
  # Only tables no deployed or current release reads or writes may be dropped
  # here: fleet history buckets/receipts and retained telemetry summaries. Any
  # unexpected dependent object MUST fail the migration rather than cascade.
  @spec up() :: :ok
  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("DROP TABLE IF EXISTS fleet_receipts")
    execute("DROP TABLE IF EXISTS fleet_buckets")
    execute("DROP TABLE IF EXISTS telemetry_summaries")
    :ok
  end

  @spec down() :: no_return()
  def down, do: raise("Dropped diagnostic archives are restored only from an export")
end
