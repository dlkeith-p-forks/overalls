defmodule Marshall.Repo.Migrations.AttachmentChunks do
  use Ecto.Migration

  def change do
    create table(:agent_attachment_chunks, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :attachment_id, references(:agent_attachments, type: :uuid, on_delete: :delete_all),
        null: false

      add :offset, :bigint, null: false
      add :size_bytes, :bigint, null: false
      add :sha256, :text, null: false
      add :encrypted_bytes, :binary, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create unique_index(:agent_attachment_chunks, [:attachment_id, :offset])

    create constraint(:agent_attachment_chunks, :attachment_chunk_bounds,
             check: "\"offset\" >= 0 AND size_bytes BETWEEN 1 AND 262144"
           )
  end
end
