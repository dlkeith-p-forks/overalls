defmodule Marshall.Repo.Migrations.ThreadReceivers do
  use Ecto.Migration

  @spec change() :: term()
  def change do
    create table(:agent_thread_receivers, primary_key: false) do
      add :id, :uuid, primary_key: true

      add :subscription_id,
          references(:agent_thread_tool_subscriptions, type: :uuid, on_delete: :delete_all),
          null: false

      add :destination_id, :uuid, null: false
      add :destination_kind, :text, null: false
      add :state, :text, null: false, default: "active"
      add :cursor, :bigint, null: false, default: 0
      add :next_attempt_at, :utc_datetime_usec
      timestamps(type: :utc_datetime_usec)
    end

    create unique_index(
             :agent_thread_receivers,
             [:subscription_id, :destination_kind, :destination_id],
             name: :agent_thread_receivers_subscription_destination_index
           )

    create constraint(:agent_thread_receivers, :thread_receiver_closed_state,
             check:
               "state IN ('active', 'inactive') AND destination_kind IN ('user_thread', 'agent_thread') AND cursor >= 0"
           )
  end
end
