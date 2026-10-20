defmodule Marshall.Repo.Migrations.ThreadToolEvents do
  use Ecto.Migration

  def change do
    create table(:agent_thread_tool_subscriptions, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :thread_id, references(:agent_threads, type: :uuid, on_delete: :delete_all), null: false
      add :owner_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :active, :boolean, null: false, default: true
      add :cursor, :bigint, null: false, default: 0
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_thread_tool_subscriptions, [:owner_id, :thread_id])

    create table(:agent_thread_tool_events, primary_key: false) do
      add :id, :uuid, primary_key: true
      add :thread_id, references(:agent_threads, type: :uuid, on_delete: :delete_all), null: false
      add :owner_id, references(:users, type: :uuid, on_delete: :delete_all), null: false
      add :sequence, :bigint, null: false
      add :kind, :text, null: false
      add :metadata, :map, null: false, default: %{}
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(:agent_thread_tool_events, [:thread_id, :sequence])
    create index(:agent_thread_tool_events, [:owner_id, :thread_id, :sequence])
  end
end
