defmodule Marshall.Repo.Migrations.RequireThreadMachineKeys do
  use Ecto.Migration

  @spec up() :: term()
  def up do
    execute("UPDATE threads SET machine_key = idempotency_key WHERE machine_key IS NULL")

    alter table(:threads) do
      modify(:machine_key, :text, null: false)
    end
  end

  @spec down() :: term()
  def down do
    alter table(:threads) do
      modify(:machine_key, :text, null: true)
    end
  end
end
