defmodule Marshall.Repo.Migrations.ArtifactChunksAndThreadStatus do
  @moduledoc """
  Byte storage for artifact blobs and guest-staged uploads (written only through
  `Marshall.Artifacts.Blobs`/`Staging`), and the database guard on the thread
  lifecycle states driven by the `Marshall.Threads.Thread` state machine.
  """
  use Ecto.Migration

  def up do
    create table(:artifact_blob_chunks, primary_key: false) do
      add :sha256,
          references(:artifact_blobs,
            column: :sha256,
            type: :text,
            on_delete: :delete_all
          ),
          primary_key: true

      add :index, :integer, primary_key: true
      add :data, :binary, null: false
    end

    create constraint(:artifact_blob_chunks, :artifact_blob_chunk_index,
             check: "index >= 0 AND octet_length(data) <= 1048576"
           )

    create table(:artifact_staged_chunks, primary_key: false) do
      add :publish_request_id,
          references(:artifact_publish_requests, type: :uuid, on_delete: :delete_all),
          primary_key: true

      add :file_index, :integer, primary_key: true
      add :chunk_index, :integer, primary_key: true
      add :sha256, :text, null: false
      add :data, :binary, null: false
      add :inserted_at, :utc_datetime_usec, null: false
    end

    create constraint(:artifact_staged_chunks, :artifact_staged_chunk_bounds,
             check:
               "file_index BETWEEN 0 AND 254 AND chunk_index >= 0 AND " <>
                 "octet_length(data) BETWEEN 1 AND 196608"
           )

    create constraint(:threads, :threads_status_valid,
             check:
               "status IN ('pending', 'provisioning', 'ready', 'failed', 'deleting', 'archived')"
           )
  end

  def down do
    drop constraint(:threads, :threads_status_valid)
    drop table(:artifact_staged_chunks)
    drop table(:artifact_blob_chunks)
  end
end
