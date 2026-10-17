defmodule Marshall.Repo.Migrations.DropLifecycleCursors do
  @moduledoc "ADR-0159 Push 5 (C1): drop the retired lifecycle cursor table."
  use Ecto.Migration

  # @cc [owner:ghuntley,label:persistence;recovery] retired-tables-drop
  # Only tables the serving release neither maps nor queries may be dropped here,
  # and only after their export; any unexpected dependent object MUST fail the
  # migration rather than cascade. The Fleet and issuance-archive tables stay
  # until the next push: the serving release's retention sweep still deletes from
  # their version tables.
  @spec up() :: :ok
  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("DROP TABLE IF EXISTS compute_lifecycle_cursors")
    :ok
  end

  @spec down() :: no_return()
  def down, do: raise("Dropped tables are restored only from an export")
end
