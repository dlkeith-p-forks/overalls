defmodule Marshall.Repo.Migrations.ThreadAttachments do
  use Ecto.Migration

  def change do
    create table(:agent_attachments, primary_key: false) do
      add(:id, :uuid, primary_key: true)
      add(:thread_id, references(:threads, type: :uuid, on_delete: :restrict), null: false)
      add(:owner_id, references(:users, type: :uuid, on_delete: :restrict), null: false)
      add(:state, :text, null: false, default: "pending")
      add(:storage_key, :text)
      add(:sha256, :text)
      add(:size_bytes, :bigint)
      add(:media_type, :text)
      add(:display_name, :text)
      add(:idempotency_key, :text, null: false)
      add(:failure_reason, :text)
      add(:download_token_hash, :text)
      add(:download_token_expires_at, :utc_datetime_usec)
      timestamps(type: :utc_datetime_usec)
    end

    create(unique_index(:agent_attachments, [:thread_id, :idempotency_key]))
    create(index(:agent_attachments, [:thread_id, :state, :inserted_at]))
  end
end
