defmodule Marshall.Repo.Migrations.RequireHostMachineId do
  @moduledoc "ADR-0159 Push 5 (M35): every enrolled host carries its physical machine identity."
  use Ecto.Migration

  # @cc [owner:ghuntley,label:persistence;security] host-machine-id-required
  # PostgreSQL MUST refuse a host without a machine ID. A host row still lacking
  # one MUST fail this migration; it is never synthesized here.
  @spec up() :: :ok
  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("ALTER TABLE compute_hosts ALTER COLUMN machine_id SET NOT NULL")
    :ok
  end

  @spec down() :: :ok
  def down do
    execute("ALTER TABLE compute_hosts ALTER COLUMN machine_id DROP NOT NULL")
    :ok
  end
end
