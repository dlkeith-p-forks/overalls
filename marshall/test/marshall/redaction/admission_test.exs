defmodule Marshall.Redaction.AdmissionTest do
  use Marshall.DataCase, async: false
  import ExUnit.CaptureLog
  import Ecto.Query

  test "unavailable admission remains closed and emits no scope or partial durable receipt" do
    scope_id = Ash.UUID.generate()
    before_runs = Marshall.Repo.aggregate(from(r in "redaction_runs"), :count)
    before_audits = Marshall.Repo.aggregate(from(a in "admin_audit_events"), :count)
    before_jobs = Marshall.Repo.aggregate(Oban.Job, :count)

    logs =
      capture_log([metadata: [:event, :run_id]], fn ->
        assert {:error, :redaction_unavailable} =
                 Marshall.Redaction.enqueue({:thread, scope_id}, nil)
      end)

    assert logs =~ "event=redaction.admission_unavailable"
    refute logs =~ scope_id
    refute logs =~ "redaction.run_requested"
    assert Marshall.Repo.aggregate(from(r in "redaction_runs"), :count) == before_runs
    assert Marshall.Repo.aggregate(from(a in "admin_audit_events"), :count) == before_audits
    assert Marshall.Repo.aggregate(Oban.Job, :count) == before_jobs
  end
end
