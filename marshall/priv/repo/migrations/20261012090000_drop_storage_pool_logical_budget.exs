defmodule Marshall.Repo.Migrations.DropStoragePoolLogicalBudget do
  @moduledoc "ADR-0159 Push 11 (H2): drop the retired storage pool logical budget column."
  use Ecto.Migration

  # @cc [owner:ghuntley,label:persistence;capacity] storage-pool-budget-drop
  # The serving release neither maps, writes nor reads this column: Push 5 removed
  # the attribute and made it nullable, and Push 10 removed every producer. Push 5's
  # storage_backend_identity CHECK already omits it, no index or version table
  # carries it, and the drop uses no CASCADE, so any unexpected dependent object
  # fails the migration. Production values are recorded in the preceding export.
  @spec up() :: :ok
  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("ALTER TABLE compute_storage_pools DROP COLUMN logical_budget_bytes")
    :ok
  end

  @spec down() :: no_return()
  def down, do: raise("The dropped pool logical budget is restored only from an export")
end
