defmodule Marshall.Repo.Migrations.TerminalV2Registry do
  use Ecto.Migration

  def up do
    execute "DROP TABLE IF EXISTS terminal_writers CASCADE"
    execute "DROP TABLE IF EXISTS terminal_writers_versions CASCADE"
    execute "DROP TABLE IF EXISTS terminal_mailboxes CASCADE"
    execute "DROP TABLE IF EXISTS terminal_connections CASCADE"
    execute "DROP TABLE IF EXISTS terminal_sessions CASCADE"
    execute "DROP TABLE IF EXISTS terminal_sessions_versions CASCADE"

    create table(:terminal_sessions, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :vm_id, :uuid, null: false
      add :owner_id, :uuid, null: false
      add :placement_id, :uuid, null: false
      add :execution_epoch, :bigint, null: false
      add :guest_session_id, :bigint, null: false
      add :guest_user, :text, null: false
      add :term, :text, null: false
      add :title, :text
      add :archived_at, :utc_datetime_usec
      timestamps()
    end

    create constraint(:terminal_sessions, "terminal_session_positive_execution_epoch",
             check: "execution_epoch > 0"
           )

    create constraint(:terminal_sessions, "terminal_session_positive_guest_session",
             check: "guest_session_id > 0"
           )

    create index(:terminal_sessions, [:vm_id], where: "archived_at IS NULL")

    create unique_index(:terminal_sessions, [:vm_id, :guest_session_id],
             where: "archived_at IS NULL"
           )

    create table(:terminal_sessions_versions, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :version_source_id, :uuid, null: false
      add :version_action_type, :text
      add :version_action_name, :text
      add :changes, :map
      add :full, :map

      add :version_inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("now()")

      add :version_updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("now()")
    end

    create index(:terminal_sessions_versions, [:version_source_id])

    create table(:terminal_events, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :vm_id, :uuid, null: false
      add :actor_id, :uuid, null: false
      add :session_id, :uuid, null: false
      add :guest_session_id, :bigint, null: false
      add :kind, :text, null: false
      add :request_id, :text
      timestamps(updated_at: false)
    end

    create constraint(:terminal_events, "terminal_events_positive_guest_session",
             check: "guest_session_id > 0"
           )

    create index(:terminal_events, [:vm_id, :inserted_at])
    create index(:terminal_events, [:actor_id, :inserted_at])
  end

  def down do
    execute "DROP TABLE IF EXISTS terminal_events CASCADE"
    execute "DROP TABLE IF EXISTS terminal_sessions CASCADE"
    execute "DROP TABLE IF EXISTS terminal_sessions_versions CASCADE"
  end
end
