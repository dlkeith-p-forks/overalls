defmodule Marshall.Repo.Migrations.TerminalKillIntent do
  use Ecto.Migration

  @spec change() :: :ok
  def change do
    alter table(:terminal_sessions) do
      add :kill_status, :text, null: false, default: "idle"
    end

    create constraint(:terminal_sessions, :terminal_session_kill_status,
             check: "kill_status IN ('idle', 'pending', 'confirmed', 'retired')"
           )
  end
end
