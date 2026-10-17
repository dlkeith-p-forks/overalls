defmodule Marshall.Repo.Migrations.MinimizeTerminalSessionRegistry do
  use Ecto.Migration

  def change do
    alter table(:terminal_sessions) do
      remove :guest_user, :text, null: false
      remove :term, :text, null: false
      remove :title, :text
    end
  end
end
