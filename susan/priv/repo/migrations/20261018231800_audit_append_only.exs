defmodule Susan.Repo.Migrations.AuditAppendOnly do
  @moduledoc """
  Makes `audit_entries` append-only in the database itself (ADR-0224).

  UPDATE and TRUNCATE are always refused. DELETE is refused unless the
  transaction set `susan.audit_prune = 'on'` (only `Susan.Audit.Log.prune/1`
  does, and it appends a `prune` entry in the same transaction) and the row is
  older than 90 days by the database clock. Privileges are revoked from PUBLIC
  as defence in depth; the trigger also binds the owning role.
  """
  use Ecto.Migration

  def up do
    execute("""
    CREATE FUNCTION susan_audit_append_only() RETURNS trigger
    LANGUAGE plpgsql SET search_path = '' AS $$
    BEGIN
      IF TG_OP = 'DELETE' THEN
        IF current_setting('susan.audit_prune', true) = 'on' THEN
          IF OLD.occurred_at < (now() AT TIME ZONE 'utc') - interval '90 days' THEN
            RETURN OLD;
          END IF;
        END IF;
      END IF;
      RAISE EXCEPTION 'audit_entries is append-only' USING ERRCODE = 'insufficient_privilege';
    END
    $$
    """)

    execute("""
    CREATE TRIGGER audit_entries_append_only
    BEFORE UPDATE OR DELETE ON audit_entries
    FOR EACH ROW EXECUTE FUNCTION susan_audit_append_only()
    """)

    execute("""
    CREATE TRIGGER audit_entries_no_truncate
    BEFORE TRUNCATE ON audit_entries
    FOR EACH STATEMENT EXECUTE FUNCTION susan_audit_append_only()
    """)

    execute("REVOKE UPDATE, DELETE, TRUNCATE ON audit_entries FROM PUBLIC")
  end

  def down do
    execute("DROP TRIGGER audit_entries_no_truncate ON audit_entries")
    execute("DROP TRIGGER audit_entries_append_only ON audit_entries")
    execute("DROP FUNCTION susan_audit_append_only()")
  end
end
