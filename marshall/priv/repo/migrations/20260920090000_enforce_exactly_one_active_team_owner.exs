defmodule Marshall.Repo.Migrations.EnforceExactlyOneActiveTeamOwner do
  @moduledoc "Enforces one current owner for every active team at transaction commit."
  use Ecto.Migration

  # @cc [owner:ghuntley,label:persistence;concurrency] active-team-owner-commit-invariant
  # Every unarchived team MUST have exactly one unarchived owner at commit.
  # Enforcement MUST be deferred so team creation and ownership swaps may use
  # temporary intermediate states inside one transaction.
  def up do
    execute("""
    DO $$
    BEGIN
      IF EXISTS (
        SELECT 1
          FROM teams
          LEFT JOIN team_members
            ON team_members.team_id = teams.id
           AND team_members.archived_at IS NULL
           AND team_members.role = 'owner'
         WHERE teams.archived_at IS NULL
         GROUP BY teams.id
        HAVING count(team_members.id) <> 1
      ) THEN
        RAISE EXCEPTION 'existing active teams must have exactly one owner'
          USING ERRCODE = '23514', CONSTRAINT = 'teams_exactly_one_active_owner';
      END IF;
    END;
    $$
    """)

    execute("""
    CREATE FUNCTION enforce_exactly_one_active_team_owner()
    RETURNS trigger
    LANGUAGE plpgsql
    AS $$
    DECLARE
      affected_team_id uuid;
      affected_team_ids uuid[];
      owner_count integer;
    BEGIN
      IF TG_TABLE_NAME = 'teams' THEN
        affected_team_ids := ARRAY[CASE WHEN TG_OP = 'DELETE' THEN OLD.id ELSE NEW.id END];
      ELSIF TG_OP = 'INSERT' THEN
        affected_team_ids := ARRAY[NEW.team_id];
      ELSIF TG_OP = 'DELETE' THEN
        affected_team_ids := ARRAY[OLD.team_id];
      ELSE
        affected_team_ids := ARRAY[OLD.team_id, NEW.team_id];
      END IF;

      FOREACH affected_team_id IN ARRAY affected_team_ids LOOP
        IF EXISTS (SELECT 1 FROM teams WHERE id = affected_team_id AND archived_at IS NULL) THEN
          SELECT count(*)
            INTO owner_count
            FROM team_members
           WHERE team_id = affected_team_id
             AND archived_at IS NULL
             AND role = 'owner';

          IF owner_count <> 1 THEN
            RAISE EXCEPTION 'active team % must have exactly one owner', affected_team_id
              USING ERRCODE = '23514', CONSTRAINT = 'teams_exactly_one_active_owner';
          END IF;
        END IF;
      END LOOP;

      RETURN NULL;
    END;
    $$
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER teams_exactly_one_active_owner
    AFTER INSERT OR UPDATE OR DELETE ON teams
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION enforce_exactly_one_active_team_owner()
    """)

    execute("""
    CREATE CONSTRAINT TRIGGER team_members_exactly_one_active_owner
    AFTER INSERT OR UPDATE OR DELETE ON team_members
    DEFERRABLE INITIALLY DEFERRED
    FOR EACH ROW EXECUTE FUNCTION enforce_exactly_one_active_team_owner()
    """)
  end

  def down do
    execute("DROP TRIGGER team_members_exactly_one_active_owner ON team_members")
    execute("DROP TRIGGER teams_exactly_one_active_owner ON teams")
    execute("DROP FUNCTION enforce_exactly_one_active_team_owner()")
  end
end
