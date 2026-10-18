defmodule Marshall.Repo.Migrations.AddPeachCredentials do
  use Ecto.Migration

  def change do
    create table(:peach_credentials, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :host_id, references(:compute_hosts, type: :uuid, on_delete: :delete_all), null: false
      add :secret_hash, :binary, null: false
      add :expires_at, :utc_datetime_usec, null: false
      add :revoked_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create index(:peach_credentials, [:host_id], where: "revoked_at IS NULL", unique: true)
  end
end
