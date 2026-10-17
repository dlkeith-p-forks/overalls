defmodule Marshall.Repo.Migrations.TerminalCreateIntents do
  use Ecto.Migration

  def change do
    alter table(:terminal_events) do
      modify :actor_id, :uuid, null: true, from: {:uuid, null: false}
    end

    create table(:terminal_openings, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :vm_id, :uuid, null: false
      add :actor_id, :uuid, null: false
      add :placement_id, :uuid, null: false
      add :execution_epoch, :bigint, null: false
      add :parameter_hash, :binary, null: false
      add :status, :text, null: false, default: "pending"
      add :session_id, :uuid
      add :expires_at, :utc_datetime_usec, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:terminal_openings, [:vm_id, :status])
    create index(:terminal_openings, [:inserted_at])

    create constraint(:terminal_openings, :terminal_opening_receipt,
             check:
               "execution_epoch > 0 AND octet_length(parameter_hash) = 32 AND ((status = 'ready' AND session_id IS NOT NULL) OR (status IN ('pending', 'cancelling', 'failed') AND session_id IS NULL))"
           )
  end
end
