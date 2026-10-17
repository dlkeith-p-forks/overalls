defmodule Marshall.Repo.Migrations.DropProtocolVersionChecks do
  @moduledoc "ADR-0159 Push 4 (B3): stop constraining the retired protocol_version columns."
  use Ecto.Migration

  # @cc [owner:ghuntley,label:persistence;protocol] protocol-version-expand
  # Only the CHECK constraints are dropped. The columns and their DEFAULT 4 MUST
  # remain until a later push so the release serving during migration can still
  # insert and update hosts and sessions.
  @spec up() :: :ok
  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("ALTER TABLE compute_hosts DROP CONSTRAINT IF EXISTS provisioner_protocol_v4")

    execute(
      "ALTER TABLE compute_host_sessions DROP CONSTRAINT IF EXISTS provisioner_protocol_history"
    )

    :ok
  end

  @spec down() :: :ok
  def down do
    execute(
      "ALTER TABLE compute_hosts ADD CONSTRAINT provisioner_protocol_v4 CHECK (protocol_version = 4)"
    )

    execute(
      "ALTER TABLE compute_host_sessions ADD CONSTRAINT provisioner_protocol_history CHECK (protocol_version IN (3, 4))"
    )

    :ok
  end
end
