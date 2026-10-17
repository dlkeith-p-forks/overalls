defmodule Marshall.Repo.Migrations.ProvisionerObservabilityCut do
  @moduledoc "Replace the provisioner v3 protocol checks with v4 defaults and checks."
  use Ecto.Migration

  @spec up() :: :ok
  def up do
    execute("ALTER TABLE compute_hosts DROP CONSTRAINT provisioner_protocol_v3")
    execute("ALTER TABLE compute_host_sessions DROP CONSTRAINT provisioner_protocol_v3")

    execute("ALTER TABLE compute_hosts ALTER COLUMN protocol_version SET DEFAULT 4")
    execute("ALTER TABLE compute_host_sessions ALTER COLUMN protocol_version SET DEFAULT 4")

    execute(
      "ALTER TABLE compute_hosts ADD CONSTRAINT provisioner_protocol_v4 CHECK (protocol_version = 4)"
    )

    execute(
      "ALTER TABLE compute_host_sessions ADD CONSTRAINT provisioner_protocol_history CHECK (protocol_version IN (3, 4))"
    )
  end

  @spec down() :: no_return()
  def down, do: raise("The coordinated provisioner cut requires a forward migration")
end
