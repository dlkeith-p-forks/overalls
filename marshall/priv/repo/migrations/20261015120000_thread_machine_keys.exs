defmodule Marshall.Repo.Migrations.ThreadMachineKeys do
  use Ecto.Migration

  def up do
    alter table(:threads) do
      add(:machine_key, :text)
    end

    execute("UPDATE threads SET machine_key = idempotency_key WHERE machine_key IS NULL")

    # The old release may still create a thread before activation completes.
    # Enforce NOT NULL after the fleet has converged on machine-key writers.
    create(unique_index(:threads, [:machine_key]))
  end

  def down do
    drop(unique_index(:threads, [:machine_key]))

    alter table(:threads) do
      remove(:machine_key)
    end
  end
end
