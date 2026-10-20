defmodule Marshall.Repo.Migrations.RedactionRuns do
  use Ecto.Migration

  def change do
    create table(:redaction_runs, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :scope, :map, null: false
      add :profile_digest, :text, null: false
      add :high_water_mark, :uuid
      add :state, :text, null: false, default: "queued"
      add :processed, :bigint, null: false, default: 0
      add :changed, :bigint, null: false, default: 0
      add :skipped, :bigint, null: false, default: 0
      add :failed, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create index(:redaction_runs, [:state, :inserted_at])

    create table(:redaction_shards, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :run_id, references(:redaction_runs, type: :uuid, on_delete: :delete_all), null: false
      add :lower_id, :uuid
      add :upper_id, :uuid
      add :state, :text, null: false, default: "queued"
      add :processed, :bigint, null: false, default: 0
      add :changed, :bigint, null: false, default: 0
      add :skipped, :bigint, null: false, default: 0
      add :error, :text
      timestamps(type: :utc_datetime_usec)
    end

    create index(:redaction_shards, [:run_id, :state])
  end
end
