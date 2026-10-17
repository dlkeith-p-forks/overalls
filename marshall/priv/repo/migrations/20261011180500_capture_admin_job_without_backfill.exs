defmodule Marshall.Repo.Migrations.CaptureAdminJobWithoutBackfill do
  @moduledoc "ADR-0159 Push 5 (C3/M34): the job capture function loses its backfill parameter."
  use Ecto.Migration

  # @cc [owner:ghuntley,label:security;durability] job-capture-trigger-only
  # The replacement MUST behave exactly as the trigger path did: the same scalar
  # fields, allowlisted UUID correlations, 30-day expiry and event deduplication.
  # It MUST drop only the retired backfill branches, and the drop and create MUST
  # commit together so the trigger never runs without its capture function.
  @spec up() :: :ok
  def up do
    execute("SET LOCAL lock_timeout = '5s'")
    execute("DROP FUNCTION marshall_capture_admin_job(oban_jobs, boolean)")

    execute("""
    CREATE FUNCTION marshall_capture_admin_job(j oban_jobs)
    RETURNS boolean LANGUAGE plpgsql AS $capture$
    DECLARE
      observed timestamp := clock_timestamp() AT TIME ZONE 'UTC';
      expiry timestamp;
      failures bigint := COALESCE(cardinality(j.errors), 0);
      previous admin_job_snapshots;
      kind text;
      subject uuid;
      reference text;
    BEGIN
      SELECT * INTO previous FROM admin_job_snapshots WHERE id = j.id;

      IF j.state::text IN ('completed', 'discarded', 'cancelled') THEN
        expiry := observed + interval '30 days';
        IF previous.id IS NOT NULL AND previous.state = j.state::text THEN
          expiry := previous.expires_at;
        END IF;
        IF expiry <= observed THEN RETURN false; END IF;
      END IF;

      kind := CASE regexp_replace(j.worker, '^Elixir[.]', '')
        WHEN 'Marshall.Compute.Workers.Dispatch' THEN 'operation'
        WHEN 'Marshall.Compute.Workers.CoordinateRelocation' THEN 'relocation'
        WHEN 'Marshall.Compute.Workers.PrepareRelocationKey' THEN 'relocation'
        WHEN 'Marshall.Compute.Workers.AdvanceDrain' THEN 'drain'
        ELSE NULL END;
      reference := j.args->'primary_key'->>'id';
      IF kind IS NOT NULL AND reference ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' THEN
        subject := reference::uuid;
      ELSE
        kind := NULL;
      END IF;

      INSERT INTO admin_job_snapshots
        (id, state, queue, worker, attempt, max_attempts, priority, error_count,
         inserted_at, scheduled_at, attempted_at, completed_at, discarded_at,
         cancelled_at, captured_at, expires_at, raw_present, subject_kind, subject_id)
      VALUES
        (j.id, j.state::text, left(j.queue, 128), left(j.worker, 256), j.attempt,
         j.max_attempts, j.priority, failures, j.inserted_at, j.scheduled_at,
         j.attempted_at, j.completed_at, j.discarded_at, j.cancelled_at,
         observed, expiry, true, kind, subject)
      ON CONFLICT (id) DO UPDATE SET
        state = EXCLUDED.state, queue = EXCLUDED.queue, worker = EXCLUDED.worker,
        attempt = EXCLUDED.attempt, max_attempts = EXCLUDED.max_attempts,
        priority = EXCLUDED.priority, error_count = EXCLUDED.error_count,
        scheduled_at = EXCLUDED.scheduled_at, attempted_at = EXCLUDED.attempted_at,
        completed_at = EXCLUDED.completed_at, discarded_at = EXCLUDED.discarded_at,
        cancelled_at = EXCLUDED.cancelled_at, captured_at = EXCLUDED.captured_at,
        expires_at = EXCLUDED.expires_at, raw_present = true,
        subject_kind = EXCLUDED.subject_kind, subject_id = EXCLUDED.subject_id;

      IF previous.id IS NULL OR
         (previous.state, previous.attempt, previous.error_count) IS DISTINCT FROM
         (j.state::text, j.attempt, failures) THEN
        INSERT INTO admin_job_events (job_id, state, attempt, error_count, captured_at, expires_at)
          VALUES (j.id, j.state::text, j.attempt, failures, observed, observed + interval '30 days');
      END IF;
      RETURN true;
    END
    $capture$
    """)

    :ok
  end

  @spec down() :: no_return()
  def down, do: raise("The job-history backfill path is retired")
end
