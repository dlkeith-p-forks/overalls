defmodule Marshall.Repo.Migrations.ReconcilePeachCredentialSchema do
  use Ecto.Migration

  # @cc [owner:ghuntley,label:persistence] peach-credential-schema-agreement
  # Existing Peach credentials MUST survive schema reconciliation. The database
  # defaults, host reference and active-host identity index MUST match Ash's
  # generated snapshots without rewriting the original table migration.
  @spec up() :: :ok
  def up do
    alter table(:peach_credentials) do
      modify(:id, :uuid, default: fragment("gen_random_uuid()"))
      modify(:inserted_at, :utc_datetime_usec, default: fragment("(now() AT TIME ZONE 'utc')"))
      modify(:updated_at, :utc_datetime_usec, default: fragment("(now() AT TIME ZONE 'utc')"))
    end

    rename(index(:peach_credentials, [:host_id]),
      to: :peach_credentials_one_active_per_host_index
    )

    drop(constraint(:peach_credentials, "peach_credentials_host_id_fkey"))

    alter table(:peach_credentials) do
      modify(
        :host_id,
        references(:compute_hosts,
          column: :id,
          name: "peach_credentials_host_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )
    end
  end

  @spec down() :: :ok
  def down do
    drop(constraint(:peach_credentials, "peach_credentials_host_id_fkey"))

    alter table(:peach_credentials) do
      modify(
        :host_id,
        references(:compute_hosts,
          column: :id,
          name: "peach_credentials_host_id_fkey",
          type: :uuid,
          prefix: "public",
          on_delete: :delete_all
        ),
        null: false
      )
    end

    rename(
      index(:peach_credentials, [:host_id], name: :peach_credentials_one_active_per_host_index),
      to: :peach_credentials_host_id_index
    )

    alter table(:peach_credentials) do
      modify(:id, :uuid, default: nil)
      modify(:inserted_at, :utc_datetime_usec, default: nil)
      modify(:updated_at, :utc_datetime_usec, default: nil)
    end
  end
end
