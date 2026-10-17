defmodule Marshall.Repo.Migrations.TerminalTickets do
  use Ecto.Migration

  def change do
    create table(:terminal_tickets, primary_key: false) do
      add :id, :uuid, null: false, primary_key: true
      add :token_hash, :text, null: false
      add :session_id, :uuid, null: false
      add :actor_id, :uuid, null: false
      add :mode, :text, null: false
      add :expires_at, :utc_datetime_usec, null: false
      timestamps(updated_at: false)
    end

    create unique_index(:terminal_tickets, [:token_hash])
    create index(:terminal_tickets, [:expires_at])
  end
end
