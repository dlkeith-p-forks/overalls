defmodule Marshall.Administration.JobsTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import ExUnit.CaptureLog
  alias Marshall.Administration
  alias Marshall.Administration.{AuditEvent, JobEvent, JobSnapshot}
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger

  setup do
    %{
      admin:
        Ash.Seed.seed!(Marshall.Accounts.User, %{
          email: "#{Ash.UUID.generate()}@example.test",
          administrator: true
        })
        |> Marshall.PasskeyFixture.verified_session()
    }
  end

  @safe_job_keys ~w(id state queue worker attempt max_attempts priority error_count inserted_at scheduled_at attempted_at completed_at discarded_at cancelled_at captured_at expires_at raw_present subject_kind subject_id retryable duration_ms queue_age_seconds failure)a
  @safe_event_keys ~w(id state attempt error_count captured_at)a

  # @cc [owner:ghuntley,label:verification;security] generated-job-projection-redaction
  # Every ordinary-reader job projection MUST use only the approved fields,
  # regardless of raw arguments, errors, state order or revoked login. A
  # revoked reader MUST receive no list or detail projection.
  property "generated mixed job histories expose only redacted fields to current readers",
    test_cases: 100 do
    states =
      draw(
        "states",
        list_of(member_of(~w(available executing retryable completed discarded cancelled)),
          min_length: 1,
          max_length: 5
        )
      )

    suffix = draw("suffix", string(:alphanumeric, min_length: 1, max_length: 32))
    shape = draw("shape", member_of([:flat, :nested, :array]))
    reader = Marshall.PasskeyFixture.user() |> Marshall.PasskeyFixture.verified_session()
    queue = "redaction_#{Ash.UUID.generate()}"
    marker = "private-#{Ash.UUID.generate()}-#{suffix}"

    args =
      case shape do
        :flat -> %{"token" => marker}
        :nested -> %{"payload" => %{"credential" => marker}}
        :array -> %{"items" => [%{"secret" => marker}]}
      end

    jobs =
      Enum.map(states, fn state ->
        job =
          args |> Oban.Job.new(worker: "Marshall.TestWorker", queue: queue) |> Oban.insert!()

        transition(job, state, errors: [%{"error" => marker, "attempt" => 1}], attempt: 1)
        job
      end)

    assert {:ok, %{items: items}} = Administration.jobs(%{queue: queue}, actor: reader)
    assert MapSet.new(Enum.map(items, & &1.id)) == MapSet.new(Enum.map(jobs, & &1.id))

    for item <- items do
      assert MapSet.new(Map.keys(item)) == MapSet.new(@safe_job_keys)
      refute inspect(item) =~ marker
    end

    for job <- jobs do
      assert {:ok, detail} = Administration.job(%{id: job.id}, actor: reader)
      assert MapSet.new(Map.keys(detail.job)) == MapSet.new(@safe_job_keys)

      assert Enum.all?(detail.events, fn event ->
               MapSet.new(Map.keys(event)) == MapSet.new(@safe_event_keys)
             end)

      refute inspect(detail) =~ marker
    end

    :ok =
      AshAuthentication.TokenResource.Actions.revoke(
        Marshall.Accounts.Token,
        reader.__metadata__.token
      )

    assert {:error, _} = Administration.jobs(%{queue: queue}, actor: reader)
    assert {:error, _} = Administration.job(%{id: hd(jobs).id}, actor: reader)
  end

  test "all job states are captured without arguments or raw exception strings", %{admin: admin} do
    marker = "secret-job-payload-#{Ash.UUID.generate()}"
    states = ~w(available suspended scheduled executing retryable completed discarded cancelled)

    jobs =
      Enum.map(states, fn state ->
        job = insert_job(%{"token" => marker})
        transition(job, state, errors: [%{"error" => marker, "attempt" => 1}], attempt: 1)
        job
      end)

    assert {:ok, page} = Administration.jobs(%{queue: "admin_test"}, actor: admin)
    assert length(page.items) == length(states)
    assert MapSet.new(Enum.map(page.items, &Atom.to_string(&1.state))) == MapSet.new(states)
    refute inspect(page) =~ marker

    for state <- [
          :available,
          :suspended,
          :scheduled,
          :executing,
          :retryable,
          :completed,
          :discarded,
          :cancelled
        ],
        do: assert(page.counts[state] >= 1)

    for job <- jobs do
      assert {:ok, detail} = Administration.job(%{id: job.id}, actor: admin)
      refute inspect(detail) =~ marker
      refute Map.has_key?(detail.job, :args)
      refute Map.has_key?(detail.job, :errors)
      assert detail.job.error_count == 1
    end
  end

  test "raw-job pruning preserves transitions and makes history view-only", %{admin: admin} do
    job = insert_job()
    transition(job, "executing", attempt: 1)
    transition(job, "discarded", attempt: 1)
    Repo.delete_all(from(j in Oban.Job, where: j.id == ^job.id))

    assert {:ok, %{job: %{raw_present: false, retryable: false}, events: events}} =
             Administration.job(%{id: job.id}, actor: admin)

    assert Enum.map(events, & &1.state) == [:discarded, :executing, :available]

    assert {:error, _} =
             Administration.retry_job(%{id: job.id, request_id: Ash.UUID.generate()},
               actor: admin
             )
  end

  test "capture rolls back with the raw job transaction" do
    assert {:error, {:fixture_rollback, id}} =
             Repo.transaction(fn ->
               job = insert_job()
               Repo.rollback({:fixture_rollback, job.id})
             end)

    assert [] == Ledger.read!(JobSnapshot, id: id)
    assert [] == Ledger.read!(JobEvent, job_id: id)
  end

  test "retry is authorized, audited, idempotent and bound to the original job", %{admin: admin} do
    job = insert_job(%{"private" => "kept-only-in-raw-job"})
    transition(job, "discarded", attempt: 2)
    request = %{id: job.id, request_id: Ash.UUID.generate()}
    assert {:ok, %{accepted: true}} = Administration.retry_job(request, actor: admin)

    assert {:ok, %{job: %{duration_ms: nil}}} = Administration.job(%{id: job.id}, actor: admin)

    assert %{state: "available", max_attempts: 3, args: %{"private" => "kept-only-in-raw-job"}} =
             Repo.get!(Oban.Job, job.id)

    assert {:ok, %{accepted: true}} = Administration.retry_job(request, actor: admin)
    assert [_] = Ledger.read!(AuditEvent, actor_id: admin.id)

    other = insert_job()
    transition(other, "discarded")
    assert {:error, _} = Administration.retry_job(%{request | id: other.id}, actor: admin)
    assert Repo.get!(Oban.Job, other.id).state == "discarded"
    Ledger.update!(admin, :assign_administrator, %{administrator: false})
    assert {:error, _} = Administration.retry_job(request, actor: admin)
    assert {:ok, _} = Administration.jobs(%{}, actor: admin)
  end

  test "ordinary users can read projections but cannot invoke internal history actions" do
    user =
      Ash.Seed.seed!(Marshall.Accounts.User, %{email: "#{Ash.UUID.generate()}@example.test"})

    assert {:ok, _} = Administration.jobs(%{}, actor: user)
    assert {:error, _} = Ash.read(JobSnapshot, actor: user)
    input = Ash.ActionInput.for_action(JobSnapshot, :expire, %{}, actor: user)
    assert {:error, _} = Ash.run_action(input)
  end

  test "running, queued, scheduled, successful and cancelled jobs cannot be retried", %{
    admin: admin
  } do
    for state <- ~w(available suspended scheduled executing completed cancelled) do
      job = insert_job()
      transition(job, state)

      assert {:error, _} =
               Administration.retry_job(%{id: job.id, request_id: Ash.UUID.generate()},
                 actor: admin
               )

      assert Repo.get!(Oban.Job, job.id).state == state
    end

    assert [] == Ledger.read!(AuditEvent)
  end

  test "expired history is hidden before physical retention and active jobs remain", %{
    admin: admin
  } do
    active = insert_job()
    old = insert_job()
    transition(old, "completed")

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE admin_job_snapshots SET expires_at = now() - interval '1 second' WHERE id = $1",
      [old.id]
    )

    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE admin_job_events SET expires_at = now() - interval '1 second' WHERE job_id = $1",
      [old.id]
    )

    assert {:error, _} = Administration.job(%{id: old.id}, actor: admin)

    assert {:ok, %{items: [%{id: id}]}} =
             Administration.jobs(%{queue: "admin_test"}, actor: admin)

    assert id == active.id
    assert {:ok, _} = internal(:expire)
    assert [] == Ledger.read!(JobSnapshot, id: old.id)
    assert [_] = Ledger.read!(JobSnapshot, id: active.id)
  end

  test "pages are bounded and filter queue, state and worker", %{admin: admin} do
    jobs = for _ <- 1..4, do: insert_job()

    assert {:ok, %{items: first, next_cursor: cursor}} =
             Administration.jobs(%{limit: 2, queue: "admin_test"}, actor: admin)

    assert length(first) == 2 and cursor

    assert {:ok, %{items: second, next_cursor: nil}} =
             Administration.jobs(%{limit: 2, before: cursor, queue: "admin_test"}, actor: admin)

    assert MapSet.new(Enum.map(first ++ second, & &1.id)) == MapSet.new(Enum.map(jobs, & &1.id))
    assert {:ok, %{items: []}} = Administration.jobs(%{queue: "absent"}, actor: admin)

    assert {:ok, %{items: []}} =
             Administration.jobs(%{state: :completed, queue: "admin_test"}, actor: admin)

    assert {:ok, %{items: []}} = Administration.jobs(%{worker: "Absent.Worker"}, actor: admin)
    assert {:error, _} = Administration.jobs(%{limit: 101}, actor: admin)
  end

  test "retry emits one structured event with the job and actor correlation", %{admin: admin} do
    job = insert_job()
    transition(job, "discarded", attempt: 1)
    request = %{id: job.id, request_id: Ash.UUID.generate()}

    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    logs =
      capture_log([metadata: [:event, :job_id, :actor_id]], fn ->
        assert {:ok, %{accepted: true}} = Administration.retry_job(request, actor: admin)
        assert {:ok, %{accepted: true}} = Administration.retry_job(request, actor: admin)
      end)

    assert logs =~ "event=admin.job_retried"
    assert logs =~ "job_id=#{job.id}"
    assert logs =~ "actor_id=#{admin.id}"
    assert length(Regex.scan(~r/event=admin\.job_retried/, logs)) == 1
  end

  defp insert_job(args \\ %{}),
    do:
      args
      |> Oban.Job.new(worker: "Marshall.TestWorker", queue: :admin_test, max_attempts: 2)
      |> Oban.insert!()

  defp transition(job, state, extra \\ []) do
    ended =
      if state in ~w(completed discarded cancelled),
        do: [{String.to_existing_atom(state <> "_at"), DateTime.utc_now()}],
        else: []

    Repo.update_all(from(j in Oban.Job, where: j.id == ^job.id),
      set: [state: state] ++ ended ++ extra
    )
  end

  defp internal(action),
    do:
      JobSnapshot
      |> Ash.ActionInput.for_action(action, %{}, actor: SystemActor.compute())
      |> Ash.run_action()
end
