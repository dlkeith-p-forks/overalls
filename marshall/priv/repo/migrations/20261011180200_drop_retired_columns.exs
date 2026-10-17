defmodule Marshall.Repo.Migrations.DropRetiredColumns do
  @moduledoc "ADR-0159 Push 5 (C2): drop host console, protocol_version and lifecycle pool columns."
  use Ecto.Migration

  # @cc [owner:ghuntley,label:persistence;protocol] retired-columns-drop
  # Only columns no attribute of the serving release maps may be dropped. Any
  # dependent object outside the table MUST fail the migration rather than
  # cascade; the wire `version` stays independent of these columns.
  @spec up() :: :ok
  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    execute("""
    ALTER TABLE compute_hosts
      DROP COLUMN console_connection_id,
      DROP COLUMN console_epoch,
      DROP COLUMN console_request_sequence,
      DROP COLUMN protocol_version
    """)

    execute("ALTER TABLE compute_host_sessions DROP COLUMN protocol_version")
    execute("ALTER TABLE compute_lifecycle_events DROP COLUMN pool_id")
    :ok
  end

  @spec down() :: no_return()
  def down, do: raise("Dropped columns are restored only from an export")
end
