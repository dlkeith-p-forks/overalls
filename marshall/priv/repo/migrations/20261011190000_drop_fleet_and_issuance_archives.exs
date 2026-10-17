defmodule Marshall.Repo.Migrations.DropFleetAndIssuanceArchives do
  @moduledoc "ADR-0159 Push 6 (C1): drop the retired Fleet and issuance archive tables."
  use Ecto.Migration

  # @cc [owner:ghuntley,label:persistence;recovery] retired-archive-drop
  # The serving release neither maps nor sweeps these tables; they were exported
  # before Push 4. Version tables drop before their sources and credentials before
  # hosts, without CASCADE, so any unexpected dependent object fails the migration.
  @spec up() :: :ok
  def up do
    execute("SET LOCAL lock_timeout = '5s'")

    for table <- ~w(
          ingress_issuances_versions
          ingress_issuances
          fleet_credentials_versions
          fleet_credentials
          fleet_hosts
        ) do
      execute("DROP TABLE IF EXISTS #{table}")
    end

    :ok
  end

  @spec down() :: no_return()
  def down, do: raise("Dropped tables are restored only from an export")
end
