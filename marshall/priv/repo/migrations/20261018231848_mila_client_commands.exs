defmodule Marshall.Repo.Migrations.MilaClientCommands do
  @moduledoc """
  Porsche client commands (ADR-0222): monotonic thread read markers and the
  SSH key that admitted each management receipt.

  Generated with `mix ash.codegen`; an unrelated pre-existing users snapshot
  drift was removed from this migration.
  """

  use Ecto.Migration

  def up do
    alter table(:ssh_requests) do
      add :ssh_key_id, :uuid
    end

    create table(:thread_read_markers, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("uuidv7()"), primary_key: true
      add :user_id, :uuid, null: false
      add :thread_id, :uuid, null: false
      add :agent_thread_id, :uuid, null: false
      add :position, :bigint, null: false, default: 0

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:thread_read_markers, [:user_id, :agent_thread_id],
             name: "thread_read_markers_one_per_reader_transcript_index"
           )

    create constraint(:thread_read_markers, :thread_read_marker_position,
             check: """
               position >= 0
             """
           )

    create index(:thread_read_markers, [:user_id, :thread_id])
  end

  def down do
    drop_if_exists index(:thread_read_markers, [:user_id, :thread_id])

    drop_if_exists constraint(:thread_read_markers, :thread_read_marker_position)

    drop_if_exists unique_index(:thread_read_markers, [:user_id, :agent_thread_id],
                     name: "thread_read_markers_one_per_reader_transcript_index"
                   )

    drop table(:thread_read_markers)

    alter table(:ssh_requests) do
      remove :ssh_key_id
    end
  end
end
