defmodule Marshall.Repo.Migrations.AddScimThreadArchiveProjections do
  use Ecto.Migration

  def change do
    create table(:scim_thread_archive_projections, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :thread_id, :uuid, null: false
      add :creator_id, :uuid, null: false
      add :title, :string
      add :objective, :text, null: false
      add :archived_at, :utc_datetime_usec, null: false
      add :reason, :string, null: false, default: "scim_retirement"
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:scim_thread_archive_projections, [:thread_id])
    create index(:scim_thread_archive_projections, [:creator_id, :archived_at])
  end
end
