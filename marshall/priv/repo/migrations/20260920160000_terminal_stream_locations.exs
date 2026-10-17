defmodule Marshall.Repo.Migrations.TerminalStreamLocations do
  use Ecto.Migration

  def change do
    create table(:terminal_stream_locations, primary_key: false) do
      add :host_id, :uuid, primary_key: true
      add :nonce, :uuid, null: false
      add :uri, :text, null: false
      add :expires_at, :utc_datetime_usec, null: false
    end
  end
end
