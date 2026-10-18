defmodule Marshall.Compute.LifecycleAuditTest do
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures
  import ExUnit.CaptureLog
  alias Marshall.Compute
  alias Marshall.Compute.{Ledger, LifecycleEvent, VirtualMachine}

  setup do
    %{host: host} = host_fixture()
    owner = user()
    {:ok, vm} = Compute.provision(request(), actor: owner)
    %{host: host, owner: owner, vm: vm}
  end

  test "audit actor identifiers must be UUIDs" do
    assert_raise ArgumentError, "invalid audit actor identifier", fn ->
      Ledger.transaction(fn -> :ok end, {:operator, "not-a-uuid"})
    end
  end

  test "human intent is attributed once; rollback retains neither mutation nor event", c do
    [created] =
      Ledger.read!(LifecycleEvent, resource_type: "VirtualMachine", resource_id: c.vm.id)

    assert created.actor_kind == :user
    assert created.actor_id == c.owner.id
    assert created.previous_state == nil
    assert created.next_state == "running"

    log =
      capture_log(fn ->
        assert {:error, :invalid_outcome} =
                 Ledger.transaction(
                   fn ->
                     [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)
                     Ledger.intent!(vm, %{desired_state: :stopped, generation: 2})
                     Ledger.rollback(:invalid_outcome)
                   end,
                   c.owner
                 )
      end)

    refute log =~ "lifecycle.transition_committed"

    assert [^created] =
             Ledger.read!(LifecycleEvent, resource_type: "VirtualMachine", resource_id: c.vm.id)

    assert [%{desired_state: :running, generation: 1}] = Ledger.read!(VirtualMachine, id: c.vm.id)
  end

  test "history requires current account authority and returns bounded safe fields", c do
    assert {:ok, _} = Compute.lifecycle_history(%{}, actor: c.owner)

    admin =
      Ledger.update!(c.owner, :assign_administrator, %{administrator: true})
      |> Marshall.PasskeyFixture.verified_session()

    assert {:ok, %{items: [event], next_cursor: cursor}} =
             Compute.lifecycle_history(%{vm_id: c.vm.id, limit: 1}, actor: admin)

    assert is_binary(cursor)
    refute Map.has_key?(event, :payload)
    refute Map.has_key?(event, :specification)

    assert {:ok, %{items: [older]}} =
             Compute.lifecycle_history(%{vm_id: c.vm.id, limit: 1, before: cursor}, actor: admin)

    assert older.id < event.id
    Ledger.update!(admin, :assign_administrator, %{administrator: false})
    assert {:ok, _} = Compute.lifecycle_history(%{}, actor: admin)
    Ledger.update!(admin, :security_state, %{deleted_at: Ledger.now()})
    assert {:error, _} = Compute.lifecycle_history(%{}, actor: admin)
  end

  test "PaperTrail retention removes expired versions without touching the live VM", c do
    Ecto.Adapters.SQL.query!(
      Repo,
      "UPDATE compute_virtual_machines_versions SET version_inserted_at = clock_timestamp() - interval '91 days' WHERE version_source_id = $1",
      [Ecto.UUID.dump!(c.vm.id)]
    )

    assert {:ok, count} = Marshall.Compute.ExpireLifecycleEvents.run(nil, nil, nil)
    assert count >= 1

    assert %{rows: [[0]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               "SELECT count(*) FROM compute_virtual_machines_versions WHERE version_source_id = $1",
               [Ecto.UUID.dump!(c.vm.id)]
             )

    assert [_] = Ledger.read!(VirtualMachine, id: c.vm.id)
  end

  test "retention is bounded and schedules continuation for a full batch" do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO compute_lifecycle_events
        (id, event_id, actor_kind, resource_type, resource_id, action, occurred_at, expires_at)
      SELECT gen_random_uuid(), gen_random_uuid(), 'system', 'Operation', gen_random_uuid(),
        'enqueue', clock_timestamp() - interval '91 days', clock_timestamp() - interval '1 day'
      FROM generate_series(1, 1001)
      """,
      []
    )

    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)

    bounded_logs =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :deleted_count]], fn ->
        assert {:ok, 1000} = Marshall.Compute.ExpireLifecycleEvents.run(nil, nil, nil)
      end)

    assert bounded_logs =~ "event=lifecycle.retention_deleted"
    assert bounded_logs =~ "deleted_count=1000"

    assert %{rows: [[1]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               "SELECT count(*) FROM compute_lifecycle_events WHERE expires_at < clock_timestamp()",
               []
             )

    assert %{rows: [[1]]} =
             Ecto.Adapters.SQL.query!(
               Repo,
               "SELECT count(*) FROM oban_jobs WHERE worker = 'Marshall.Compute.Workers.ExpireLifecycleEvents'",
               []
             )

    assert {:ok, 1} = Marshall.Compute.ExpireLifecycleEvents.run(nil, nil, nil)
  end

  # @cc [owner:ghuntley,label:verification;durability] generated-retention-drain
  # Each generated expired backlog MUST drain in batches of at most 1000 rows;
  # every full batch MUST enqueue one maintenance continuation, including an
  # exact multiple of 1000, while a partial or empty batch MUST enqueue none.
  test "generated expired backlogs drain with one continuation per full batch", c do
    check all(offset <- integer(1..200), test_cases: 4) do
      for backlog <- [0, offset, 1000, 1000 + offset, 2000] do
        assert_retention_backlog(backlog, c.vm.id)
      end
    end
  end

  @spec assert_retention_backlog(non_neg_integer(), Ash.UUID.t()) :: :ok
  defp assert_retention_backlog(backlog, vm_id) do
    Ecto.Adapters.SQL.query!(
      Repo,
      """
      INSERT INTO compute_lifecycle_events
        (id, event_id, actor_kind, resource_type, resource_id, action, occurred_at, expires_at)
      SELECT gen_random_uuid(), gen_random_uuid(), 'system', 'Operation', gen_random_uuid(),
        'enqueue', clock_timestamp() - interval '91 days', clock_timestamp() - interval '1 day'
      FROM generate_series(1, $1)
      """,
      [backlog]
    )

    passes = max(1, div(backlog + 999, 1000))

    for pass <- 1..passes do
      expected = min(1000, max(0, backlog - (pass - 1) * 1000))
      assert {:ok, ^expected} = Marshall.Compute.ExpireLifecycleEvents.run(nil, nil, nil)

      assert %{rows: [[remaining]]} =
               Ecto.Adapters.SQL.query!(
                 Repo,
                 "SELECT count(*) FROM compute_lifecycle_events WHERE expires_at < clock_timestamp()",
                 []
               )

      assert remaining == max(0, backlog - pass * 1000)

      assert %{rows: [[continuations]]} =
               Ecto.Adapters.SQL.query!(
                 Repo,
                 """
                 SELECT count(*) FROM oban_jobs
                 WHERE worker = 'Marshall.Compute.Workers.ExpireLifecycleEvents'
                   AND queue = 'maintenance'
                 """,
                 []
               )

      assert continuations == min(pass, div(backlog, 1000))
    end

    assert [_] = Ledger.read!(VirtualMachine, id: vm_id)

    Ecto.Adapters.SQL.query!(
      Repo,
      "DELETE FROM oban_jobs WHERE worker = 'Marshall.Compute.Workers.ExpireLifecycleEvents'",
      []
    )

    :ok
  end
end
