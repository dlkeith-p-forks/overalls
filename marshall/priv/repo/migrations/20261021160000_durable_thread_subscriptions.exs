defmodule Marshall.Repo.Migrations.DurableThreadSubscriptions do
  use Ecto.Migration

  # @cc [owner:ghuntley,label:persistence;recovery] subscription-user-thread-provenance
  # Migration MUST preserve origin IDs and existing cursors. Unmappable or
  # conflicting histories MUST fail transactionally rather than discard data.
  # Old writers MUST acquire durable user-thread attribution during rollout.
  @spec up() :: term()
  def up do
    for name <- [:agent_thread_tool_subscriptions, :agent_thread_tool_events] do
      alter table(name) do
        add :user_thread_id, references(:threads, type: :uuid, on_delete: :delete_all)
      end
    end

    execute """
    CREATE FUNCTION thread_tool_user_binding(origin uuid) RETURNS uuid
    LANGUAGE plpgsql AS $$
    DECLARE resolved uuid; matches integer;
    BEGIN
      SELECT count(*), (array_agg(id))[1] INTO matches, resolved FROM (
        SELECT id FROM threads WHERE agent_thread_id = origin
        UNION
        SELECT thread_id FROM thread_generations WHERE agent_thread_id = origin
      ) bindings;
      IF matches <> 1 THEN
        RAISE EXCEPTION 'thread tool origin must resolve to one durable user thread';
      END IF;
      RETURN resolved;
    END $$
    """

    for name <- [:agent_thread_tool_subscriptions, :agent_thread_tool_events] do
      execute "UPDATE #{name} SET user_thread_id = thread_tool_user_binding(thread_id)"
      execute "ALTER TABLE #{name} ALTER COLUMN user_thread_id SET NOT NULL"
    end

    create unique_index(:agent_thread_tool_subscriptions, [:owner_id, :user_thread_id],
             name: :agent_thread_tool_subscriptions_owner_user_thread_index
           )

    create unique_index(:agent_thread_tool_events, [:user_thread_id, :sequence],
             name: :agent_thread_tool_events_user_thread_sequence_index
           )

    execute """
    CREATE FUNCTION thread_tool_attribute_user() RETURNS trigger LANGUAGE plpgsql AS $$
    DECLARE resolved uuid;
    BEGIN
      resolved := thread_tool_user_binding(NEW.thread_id);
      IF NEW.user_thread_id IS NOT NULL AND NEW.user_thread_id <> resolved THEN
        RAISE EXCEPTION 'thread tool origin does not match durable user thread';
      END IF;
      IF TG_TABLE_NAME = 'agent_thread_tool_events' AND NEW.user_thread_id IS NULL THEN
        PERFORM pg_advisory_xact_lock(hashtextextended('thread-notification:' || resolved::text, 0));
        SELECT COALESCE(max(sequence), 0) + 1 INTO NEW.sequence
          FROM agent_thread_tool_events WHERE user_thread_id = resolved;
      END IF;
      NEW.user_thread_id := resolved;
      RETURN NEW;
    END $$
    """

    for name <- [:agent_thread_tool_subscriptions, :agent_thread_tool_events] do
      execute "CREATE TRIGGER thread_tool_attribute_user BEFORE INSERT ON #{name} FOR EACH ROW EXECUTE FUNCTION thread_tool_attribute_user()"
    end
  end

  @spec down() :: no_return()
  def down do
    raise "Durable subscriptions require an explicit export and reviewed rollback; generation cursors cannot be restored automatically"
  end
end
