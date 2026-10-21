defmodule Marshall.Repo.Migrations.AttachmentAudits do
  use Ecto.Migration

  def change do
    create table(:agent_attachment_audits, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :attachment_id, :uuid, null: false
      add :thread_id, :uuid, null: false
      add :actor_id, :uuid, null: false
      add :operation, :text, null: false
      add :outcome, :text, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create index(:agent_attachment_audits, [:thread_id, :inserted_at, :id])
    create index(:agent_attachment_audits, [:attachment_id, :inserted_at, :id])
  end
end
