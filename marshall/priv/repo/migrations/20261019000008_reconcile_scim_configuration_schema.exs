defmodule Marshall.Repo.Migrations.ReconcileScimConfigurationSchema do
  use Ecto.Migration

  # Marshall.Scim.Configuration is an AshArchival resource with a UUID primary
  # key, but 20261019000001 created a bigserial id and no archived_at column,
  # so every read of the resource failed on undefined_column. Nothing references
  # the singleton row by id, so it keeps its data under a fresh UUID.
  def up do
    alter table(:scim_configurations) do
      add :archived_at, :utc_datetime_usec
    end

    execute "ALTER TABLE scim_configurations DROP CONSTRAINT scim_configurations_pkey"
    execute "ALTER TABLE scim_configurations ALTER COLUMN id DROP DEFAULT"
    execute "ALTER TABLE scim_configurations ALTER COLUMN id TYPE uuid USING gen_random_uuid()"
    execute "ALTER TABLE scim_configurations ADD PRIMARY KEY (id)"
    execute "DROP SEQUENCE IF EXISTS scim_configurations_id_seq"
  end

  def down do
    execute "ALTER TABLE scim_configurations DROP CONSTRAINT scim_configurations_pkey"
    execute "CREATE SEQUENCE IF NOT EXISTS scim_configurations_id_seq"

    execute "ALTER TABLE scim_configurations ALTER COLUMN id TYPE bigint " <>
              "USING nextval('scim_configurations_id_seq')"

    execute "ALTER TABLE scim_configurations " <>
              "ALTER COLUMN id SET DEFAULT nextval('scim_configurations_id_seq')"

    execute "ALTER SEQUENCE scim_configurations_id_seq OWNED BY scim_configurations.id"
    execute "ALTER TABLE scim_configurations ADD PRIMARY KEY (id)"

    alter table(:scim_configurations) do
      remove :archived_at
    end
  end
end
