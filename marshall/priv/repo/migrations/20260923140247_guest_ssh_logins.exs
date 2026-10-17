defmodule Marshall.Repo.Migrations.GuestSshLogins do
  use Ecto.Migration

  def change do
    create table(:ssh_guest_logins, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :vm_id, :uuid, null: false
      add :user_id, :uuid, null: false
      add :key_id, :uuid, null: false
      add :host_id, :uuid, null: false
      add :placement_id, :uuid, null: false
      add :execution_epoch, :bigint, null: false

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create index(:ssh_guest_logins, [:vm_id, :inserted_at])
    create index(:ssh_guest_logins, [:key_id, :inserted_at])
  end
end
