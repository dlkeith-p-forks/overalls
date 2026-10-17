defmodule Marshall.Repo.Migrations.GuestAccounts do
  use Ecto.Migration

  def up do
    execute(
      "CREATE SEQUENCE account_guest_roster_seq AS bigint START WITH 1 INCREMENT BY 1 NO CYCLE"
    )

    execute(
      "CREATE SEQUENCE account_guest_uid_seq AS integer START WITH 200000 INCREMENT BY 1 MINVALUE 200000 MAXVALUE 999999 NO CYCLE"
    )

    create table(:account_guest_accounts, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :user_id, references(:users, type: :uuid, on_delete: :restrict), null: false
      add :username, :text, null: false
      add :uid, :bigint, null: false
      add :retired_at, :utc_datetime_usec

      add :inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end

    create unique_index(:account_guest_accounts, [:username],
             name: :account_guest_accounts_username_never_reused_index
           )

    create unique_index(:account_guest_accounts, [:uid],
             name: :account_guest_accounts_uid_never_reused_index
           )

    create unique_index(:account_guest_accounts, [:user_id],
             where: "retired_at IS NULL",
             name: :account_guest_accounts_current_user_index
           )

    create constraint(:account_guest_accounts, :account_guest_accounts_uid_range,
             check: "uid BETWEEN 200000 AND 999999"
           )

    create constraint(:account_guest_accounts, :account_guest_accounts_name_format,
             check:
               "(username ~ '^[a-z_][a-z0-9_.-]{0,30}[a-z0-9_]$' OR username ~ '^[a-z_]$') AND username NOT IN ('root', 'daemon', 'bin', 'sys', 'sync', 'games', 'man', 'lp', 'mail', 'news', 'uucp', 'proxy', 'www-data', 'backup', 'list', 'irc', 'gnats', 'nobody', 'ubuntu', 'sshd', 'sudo', 'postgres') AND username NOT LIKE 'systemd-%' AND username NOT LIKE 'nixbld%'"
           )

    create table(:account_guest_accounts_versions, primary_key: false) do
      add :id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true
      add :version_action_type, :text, null: false
      add :version_action_name, :text, null: false

      add :version_source_id,
          references(:account_guest_accounts, type: :uuid, on_delete: :restrict),
          null: false

      add :changes, :map
      add :actor_kind, :text
      add :actor_id, :uuid

      add :version_inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")

      add :version_updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
    end
  end

  def down do
    execute("DROP SEQUENCE account_guest_roster_seq")
    drop table(:account_guest_accounts_versions)
    drop table(:account_guest_accounts)
    execute("DROP SEQUENCE account_guest_uid_seq")
  end
end
