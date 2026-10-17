defmodule Marshall.Repo.Migrations.RelaxStoragePoolBudget do
  @moduledoc "ADR-0159 Push 5 (A2/H1): Marshall stops requiring the retired pool logical budget."
  use Ecto.Migration

  # @cc [owner:ghuntley,label:persistence;capacity] storage-pool-budget-relaxed
  # The column MUST remain, nullable, because the release serving during this
  # migration still writes it; a later push drops it. The replacement CHECK MUST
  # keep every ZFS identity clause and drop only the budget clauses.
  @spec up() :: :ok
  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("ALTER TABLE compute_storage_pools ALTER COLUMN logical_budget_bytes DROP NOT NULL")

    execute(
      "ALTER TABLE compute_storage_pools DROP CONSTRAINT storage_backend_identity_and_budget"
    )

    execute("""
    ALTER TABLE compute_storage_pools ADD CONSTRAINT storage_backend_identity CHECK (
      backend = 'zfs' AND zpool_guid IS NOT NULL AND dataset_guid IS NOT NULL
        AND dataset IS NOT NULL
        AND filesystem_id = 'zfs:' || zpool_guid || ':' || dataset_guid)
    """)

    :ok
  end

  @spec down() :: no_return()
  def down, do: raise("Budget-less pools cannot regain a required logical budget")
end
