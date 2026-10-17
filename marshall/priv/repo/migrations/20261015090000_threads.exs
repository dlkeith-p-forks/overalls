defmodule Marshall.Repo.Migrations.Threads do
  use Ecto.Migration

  def up do
    alter table(:agent_threads) do
      add(:mode, :text, null: false, default: "medium")
    end

    create(
      constraint(:agent_threads, :agent_threads_mode_check,
        check: "mode IN ('low', 'medium', 'high', 'ultra')"
      )
    )

    create table(:threads, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("uuidv7()"), primary_key: true)
      add(:creator_id, references(:users, type: :uuid, on_delete: :restrict), null: false)
      add(:team_id, references(:teams, type: :uuid, on_delete: :restrict))
      add(:title, :text)
      add(:objective, :text, null: false)
      add(:mode, :text, null: false, default: "medium")
      add(:machine_spec, :map, null: false)
      add(:machine_id, :uuid)
      add(:agent_root_id, :uuid)
      add(:agent_thread_id, :uuid)
      add(:idempotency_key, :text, null: false)
      add(:status, :text, null: false, default: "pending")
      add(:failure_reason, :text)
      add(:archived_at, :utc_datetime_usec)

      add(:inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end

    create(unique_index(:threads, [:idempotency_key]))
    create(index(:threads, [:creator_id, :inserted_at]))
    create(index(:threads, [:team_id, :inserted_at]))

    create(
      constraint(:threads, :threads_mode_check,
        check: "mode IN ('low', 'medium', 'high', 'ultra')"
      )
    )

    create(
      constraint(:threads, :threads_status_check,
        check: "status IN ('pending', 'provisioning', 'ready', 'failed', 'deleting', 'archived')"
      )
    )

    create table(:threads_versions, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("gen_random_uuid()"), primary_key: true)
      add(:version_action_type, :text, null: false)
      add(:version_action_name, :text, null: false)
      add(:actor_kind, :text)
      add(:actor_id, :uuid)

      add(
        :version_source_id,
        references(:threads,
          column: :id,
          name: "threads_versions_version_source_id_fkey",
          type: :uuid,
          prefix: "public"
        ),
        null: false
      )

      add(:changes, :map)

      add(:version_inserted_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )

      add(:version_updated_at, :utc_datetime_usec,
        null: false,
        default: fragment("(now() AT TIME ZONE 'utc')")
      )
    end
  end

  def down do
    drop constraint(:threads_versions, "threads_versions_version_source_id_fkey")
    drop(table(:threads_versions))
    drop(table(:threads))
    drop(constraint(:agent_threads, :agent_threads_mode_check))

    alter table(:agent_threads) do
      remove(:mode)
    end
  end
end
