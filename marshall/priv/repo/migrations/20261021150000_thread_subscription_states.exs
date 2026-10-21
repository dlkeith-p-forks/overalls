defmodule Marshall.Repo.Migrations.ThreadSubscriptionStates do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE agent_thread_tool_subscriptions ALTER COLUMN active DROP DEFAULT"

    execute "ALTER TABLE agent_thread_tool_subscriptions ALTER COLUMN active TYPE text USING CASE WHEN active THEN 'active' ELSE 'inactive' END"

    rename table(:agent_thread_tool_subscriptions), :active, to: :state
    execute "ALTER TABLE agent_thread_tool_subscriptions ALTER COLUMN state SET DEFAULT 'active'"

    create constraint(:agent_thread_tool_subscriptions, :thread_subscription_state,
             check: "state IN ('active', 'inactive')"
           )
  end

  def down do
    drop constraint(:agent_thread_tool_subscriptions, :thread_subscription_state)
    execute "ALTER TABLE agent_thread_tool_subscriptions ALTER COLUMN state DROP DEFAULT"

    execute "ALTER TABLE agent_thread_tool_subscriptions ALTER COLUMN state TYPE boolean USING state = 'active'"

    rename table(:agent_thread_tool_subscriptions), :state, to: :active
    execute "ALTER TABLE agent_thread_tool_subscriptions ALTER COLUMN active SET DEFAULT true"
  end
end
