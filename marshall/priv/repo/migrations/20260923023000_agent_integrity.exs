defmodule Marshall.Repo.Migrations.AgentIntegrity do
  use Ecto.Migration

  def up do
    execute "ALTER TABLE agent_threads ADD CONSTRAINT agent_threads_root_fk FOREIGN KEY (root_id) REFERENCES agent_roots(id)"

    execute "ALTER TABLE agent_threads ADD CONSTRAINT agent_threads_parent_fk FOREIGN KEY (parent_thread_id) REFERENCES agent_threads(id)"

    execute "ALTER TABLE agent_turns ADD CONSTRAINT agent_turns_thread_fk FOREIGN KEY (thread_id) REFERENCES agent_threads(id)"

    execute "ALTER TABLE agent_events ADD CONSTRAINT agent_events_thread_fk FOREIGN KEY (thread_id) REFERENCES agent_threads(id)"

    execute "ALTER TABLE agent_events ADD CONSTRAINT agent_events_turn_fk FOREIGN KEY (turn_id) REFERENCES agent_turns(id)"

    execute "ALTER TABLE agent_executors ADD CONSTRAINT agent_executors_root_fk FOREIGN KEY (root_id) REFERENCES agent_roots(id)"

    execute "ALTER TABLE agent_commands ADD CONSTRAINT agent_commands_root_fk FOREIGN KEY (root_id) REFERENCES agent_roots(id)"

    execute "ALTER TABLE agent_commands ADD CONSTRAINT agent_commands_thread_fk FOREIGN KEY (thread_id) REFERENCES agent_threads(id)"

    execute "ALTER TABLE agent_commands ADD CONSTRAINT agent_commands_turn_fk FOREIGN KEY (turn_id) REFERENCES agent_turns(id)"

    execute "ALTER TABLE agent_commands ADD CONSTRAINT agent_commands_executor_fk FOREIGN KEY (executor_id) REFERENCES agent_executors(id)"

    execute "ALTER TABLE agent_turns ADD CONSTRAINT agent_turns_status_check CHECK (status IN ('queued','running','completed','failed','interrupted'))"

    execute "ALTER TABLE agent_commands ADD CONSTRAINT agent_commands_status_check CHECK (status IN ('queued','claimed','started','completed','failed','uncertain','cancelled'))"

    execute "ALTER TABLE agent_threads ADD CONSTRAINT agent_threads_event_sequence_check CHECK (next_event_sequence >= 1)"

    execute "ALTER TABLE agent_executors ADD CONSTRAINT agent_executors_fence_check CHECK (fence_epoch >= 1 AND execution_epoch >= 1)"
  end

  def down do
    execute "ALTER TABLE agent_executors DROP CONSTRAINT agent_executors_fence_check"
    execute "ALTER TABLE agent_threads DROP CONSTRAINT agent_threads_event_sequence_check"
    execute "ALTER TABLE agent_commands DROP CONSTRAINT agent_commands_status_check"
    execute "ALTER TABLE agent_turns DROP CONSTRAINT agent_turns_status_check"
    execute "ALTER TABLE agent_commands DROP CONSTRAINT agent_commands_executor_fk"
    execute "ALTER TABLE agent_commands DROP CONSTRAINT agent_commands_turn_fk"
    execute "ALTER TABLE agent_commands DROP CONSTRAINT agent_commands_thread_fk"
    execute "ALTER TABLE agent_commands DROP CONSTRAINT agent_commands_root_fk"
    execute "ALTER TABLE agent_executors DROP CONSTRAINT agent_executors_root_fk"
    execute "ALTER TABLE agent_events DROP CONSTRAINT agent_events_turn_fk"
    execute "ALTER TABLE agent_events DROP CONSTRAINT agent_events_thread_fk"
    execute "ALTER TABLE agent_turns DROP CONSTRAINT agent_turns_thread_fk"
    execute "ALTER TABLE agent_threads DROP CONSTRAINT agent_threads_parent_fk"
    execute "ALTER TABLE agent_threads DROP CONSTRAINT agent_threads_root_fk"
  end
end
