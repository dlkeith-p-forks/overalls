defmodule Marshall.Repo.Migrations.ThreadGenerations do
  use Ecto.Migration

  def up do
    create table(:thread_generations, primary_key: false) do
      add(:id, :uuid, null: false, default: fragment("uuidv7()"), primary_key: true)
      add(:thread_id, references(:threads, type: :uuid, on_delete: :restrict), null: false)
      add(:ordinal, :integer, null: false)
      add(:machine_key, :text, null: false)
      add(:machine_id, :uuid)
      add(:agent_root_id, :uuid)
      add(:agent_thread_id, :uuid)
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

    create(unique_index(:thread_generations, [:thread_id, :ordinal]))
    create(unique_index(:thread_generations, [:thread_id, :machine_key]))
    create(index(:thread_generations, [:agent_thread_id]))

    create constraint(:thread_generations, :thread_generations_ordinal_check,
             check: "ordinal > 0"
           )

    create constraint(:thread_generations, :thread_generations_status_check,
             check:
               "status IN ('pending', 'provisioning', 'ready', 'failed', 'deleting', 'archived')"
           )

    execute("""
    INSERT INTO thread_generations
      (thread_id, ordinal, machine_key, machine_id, agent_root_id, agent_thread_id,
       status, failure_reason, archived_at, inserted_at, updated_at)
    SELECT id, 1, machine_key, machine_id, agent_root_id, agent_thread_id,
           status, failure_reason, archived_at, inserted_at, updated_at
    FROM threads
    ON CONFLICT (thread_id, ordinal) DO NOTHING
    """)
  end

  def down do
    drop constraint(:thread_generations, :thread_generations_status_check)
    drop constraint(:thread_generations, :thread_generations_ordinal_check)
    drop_if_exists unique_index(:thread_generations, [:thread_id, :machine_key])
    drop_if_exists unique_index(:thread_generations, [:thread_id, :ordinal])
    drop_if_exists index(:thread_generations, [:agent_thread_id])
    drop table(:thread_generations)
  end
end
