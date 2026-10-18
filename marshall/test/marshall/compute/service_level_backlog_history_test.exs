defmodule Marshall.Compute.ServiceLevelBacklogHistoryTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen

  alias Marshall.Compute.{
    Ledger,
    Operation,
    ServiceLevelAttempt,
    ServiceLevelTotal,
    ServiceLevelPublisher,
    WorkflowServiceLevelAttempt
  }

  alias Marshall.ComputeFixtures, as: Fixtures

  @moduletag timeout: 180_000
  @duration_bounds [
    1_000_000,
    5_000_000,
    10_000_000,
    30_000_000,
    120_000_000,
    600_000_000,
    3_000_000_000
  ]

  # @cc [owner:ghuntley,label:verification;accounting] mixed-backlog-publication-history
  # Generated overdue/future mixtures MUST conserve terminal totals and immutable
  # deadlines through bounded scans. Any remaining overdue attempt MUST withhold
  # fresh files; future attempts MUST NOT prevent eventual publication. Synthetic
  # clocks and rollback are sandbox controls, not native recovery evidence.
  # Operation and workflow families MUST each exercise the shared publication
  # guard; finished rows, SSH receipts and execution allocations MUST remain
  # immutable while the other pending rows drain.
  # The native input timer includes each real database history; the scoped CI
  # profile permits those histories without reducing their generated cases.
  property "mixed deadline backlogs preserve totals and refuse premature freshness",
    profile: :ci,
    test_cases: 4 do
    check all(
            overdue <- member_of([0, 1, 99, 100, 101, 102]),
            future_first <- boolean(),
            family <- member_of([:operation, :workflow]),
            test_cases: 4
          ) do
      for {kind, expired, first} <- [
            {family, overdue, future_first},
            {:operation, 0, true},
            {:operation, 99, true},
            {:operation, 100, false},
            {:operation, 101, true},
            {:operation, 102, false},
            {:workflow, 0, true},
            {:workflow, 99, true},
            {:workflow, 100, false},
            {:workflow, 101, true},
            {:workflow, 102, false}
          ] do
        :ok = Ecto.Adapters.SQL.Sandbox.checkout(Marshall.Repo)

        try do
          :ok = backlog_history(kind, expired, first)
        after
          :ok = Ecto.Adapters.SQL.Sandbox.checkin(Marshall.Repo)
        end
      end
    end
  end

  @type family :: :operation | :workflow
  @type attempt :: ServiceLevelAttempt.t() | WorkflowServiceLevelAttempt.t()

  @spec backlog_history(family(), 0..102, boolean()) :: :ok
  defp backlog_history(kind, expired, future_first) do
    Fixtures.host_fixture()
    actor = Fixtures.user()
    assert {:ok, vm} = Marshall.Compute.provision(Fixtures.request(), actor: actor)
    seed_attempts(kind, vm, actor)

    attempts = attempts(kind) |> Enum.sort_by(& &1.id)
    assert length(attempts) == 102
    expired_ids = attempts |> Enum.take(expired) |> Enum.map(& &1.id)
    directory = Path.join(System.tmp_dir!(), "slo-history-#{Ash.UUID.generate()}")
    File.mkdir_p!(directory)

    try do
      assert :ok = ServiceLevelPublisher.publish(directory)
      before_files = backlog_files(directory)
      now = Ledger.now()
      admitted = DateTime.add(now, -3600)
      past = DateTime.add(now, -1)
      future = DateTime.add(now, 86_400)

      for attempt <- attempts do
        overdue? = attempt.id in expired_ids
        first? = overdue? != future_first
        checked = DateTime.add(now, if(first?, do: -120, else: -60))

        assert %{num_rows: 1} =
                 Ecto.Adapters.SQL.query!(
                   Marshall.Repo,
                   "UPDATE #{attempt_table(kind)} SET admitted_at=$1, deadline=$2, checked_at=$3 WHERE id=$4",
                   [
                     DateTime.to_naive(admitted),
                     DateTime.to_naive(if(overdue?, do: past, else: future)),
                     DateTime.to_naive(checked),
                     Ecto.UUID.dump!(attempt.id)
                   ],
                   log: false
                 )
      end

      deadlines = Map.new(attempts(kind), &{&1.id, &1.deadline})
      operations = backlog_operations()
      authority = execution_inventory()

      lifetimes =
        Map.new(Ledger.read!(ServiceLevelTotal, []), &{&1.service, {&1.id, &1.started_at}})

      Enum.reduce(1..3, {before_files, %{}}, fn scan, {previous_files, previous_terminal} ->
        result = ServiceLevelPublisher.publish(directory)
        rows = attempts(kind)
        finished = Enum.filter(rows, &(&1.status == :finished))
        terminal = Map.new(finished, &{&1.id, &1})
        assert Map.take(terminal, Map.keys(previous_terminal)) == previous_terminal
        remaining = Enum.count(rows, &(&1.id in expired_ids and &1.status == :pending))

        expected =
          if scan == 1 do
            if future_first, do: max(expired - 2, 0), else: min(expired, 100)
          else
            expired
          end

        assert length(finished) == expected

        assert Enum.all?(rows, fn row ->
                 row.id in expired_ids or
                   (row.status == :pending and row.success == nil and row.completed_at == nil)
               end)

        assert Enum.sort(Enum.map(finished, & &1.id)) ==
                 Enum.sort(
                   expired_ids -- Enum.map(Enum.filter(rows, &(&1.status == :pending)), & &1.id)
                 )

        assert Enum.all?(finished, &(&1.success == false and &1.completed_at == past))
        assert Map.new(rows, &{&1.id, &1.deadline}) == deadlines
        assert backlog_operations() == operations
        assert execution_inventory() == authority
        totals = Ledger.read!(ServiceLevelTotal, [])
        assert Map.new(totals, &{&1.service, {&1.id, &1.started_at}}) == lifetimes

        for total <- totals do
          count = Enum.count(finished, &(&1.service == total.service))
          assert total.requests == count
          assert total.failures == count
          assert total.successes == 0
          duration = DateTime.diff(past, admitted, :microsecond)

          bucket =
            Enum.find_index(@duration_bounds, &(duration <= &1)) || length(@duration_bounds)

          expected_buckets =
            List.duplicate(0, length(@duration_bounds) + 1) |> List.replace_at(bucket, count)

          assert total.bucket_counts == expected_buckets
          assert total.duration_sum_us == count * duration
        end

        if remaining > 0 do
          assert result == :error
          assert backlog_files(directory) == previous_files
          {previous_files, terminal}
        else
          assert result == :ok

          samples =
            for total <- totals do
              name = "#{total.service}.json"
              snapshot = directory |> Path.join(name) |> File.read!() |> Jason.decode!()
              prior = previous_files |> Map.fetch!(name) |> Jason.decode!()
              assert snapshot["sampled_at_unix_nano"] > prior["sampled_at_unix_nano"]
              identity = String.replace(total.id, "-", "")
              assert snapshot["incarnation"] == identity
              assert snapshot["invocation_id"] == identity

              assert snapshot["started_at_unix_nano"] ==
                       DateTime.to_unix(total.started_at, :nanosecond)

              assert snapshot["requests"] == total.requests
              assert snapshot["failures"] == total.failures
              assert snapshot["successes"] == total.successes
              assert snapshot["duration"]["bucket_counts"] == total.bucket_counts
              assert snapshot["duration"]["count"] == total.requests
              assert snapshot["duration"]["sum_us"] == total.duration_sum_us
              snapshot["sampled_at_unix_nano"]
            end

          assert length(Enum.uniq(samples)) == 1
          {backlog_files(directory), terminal}
        end
      end)

      assert Enum.count(attempts(kind), &(&1.status == :finished)) ==
               expired

      :ok
    after
      File.rm_rf!(directory)
    end
  end

  @spec seed_attempts(family(), Marshall.Compute.VirtualMachine.t(), Marshall.Accounts.User.t()) ::
          :ok
  defp seed_attempts(:operation, vm, actor) do
    [operation] = Ledger.read!(Operation, vm_id: vm.id, kind: :provision)

    for generation <- 2..51 do
      Ledger.create!(Operation, :enqueue, %{
        vm_id: vm.id,
        placement_id: operation.placement_id,
        execution_epoch: operation.execution_epoch,
        requested_by_id: actor.id,
        generation: generation,
        kind: :provision,
        request_key: Ash.UUID.generate()
      })
    end

    :ok
  end

  defp seed_attempts(:workflow, vm, actor) do
    assert {:ok, clone} =
             Marshall.Compute.clone(%{vm_id: vm.id, idempotency_key: Ash.UUID.generate()},
               actor: actor
             )

    for _ <- 1..102 do
      Ledger.create!(Marshall.SSH.Request, :record, %{
        request_id: Ash.UUID.generate(),
        user_id: actor.id,
        vm_id: vm.id,
        clone_request_id: clone.id,
        status: :accepted,
        result: %{},
        command: %{"command" => "clone"},
        measurement_started_at: Ledger.now()
      })
    end

    :ok
  end

  @spec attempts(family()) :: [attempt()]
  defp attempts(:operation), do: Ledger.read!(ServiceLevelAttempt)
  defp attempts(:workflow), do: Ledger.read!(WorkflowServiceLevelAttempt)

  @spec attempt_table(family()) :: String.t()
  defp attempt_table(:operation), do: "compute_service_level_attempts"
  defp attempt_table(:workflow), do: "compute_workflow_service_level_attempts"

  @type authority :: {
          [Marshall.Compute.VirtualMachine.t()],
          [Marshall.Compute.Reservation.t()],
          [Marshall.Compute.CloneRequest.t()],
          [Marshall.SSH.Request.t()],
          [Marshall.Compute.WorkloadPlacement.t()],
          [Marshall.Compute.NetworkAddress.t()],
          [Marshall.Compute.TransferSlot.t()]
        }
  @spec execution_inventory() :: authority()
  defp execution_inventory do
    {
      Enum.sort_by(Ledger.read!(Marshall.Compute.VirtualMachine), & &1.id),
      Enum.sort_by(Ledger.read!(Marshall.Compute.Reservation), & &1.id),
      Enum.sort_by(Ledger.read!(Marshall.Compute.CloneRequest), & &1.id),
      Enum.sort_by(Ledger.read!(Marshall.SSH.Request), & &1.id),
      Enum.sort_by(Ledger.read!(Marshall.Compute.WorkloadPlacement), & &1.id),
      Enum.sort_by(Ledger.read!(Marshall.Compute.NetworkAddress), & &1.id),
      Enum.sort_by(Ledger.read!(Marshall.Compute.TransferSlot), & &1.id)
    }
  end

  @spec backlog_operations() :: %{OverallsProtocol.uuid() => Operation.t()}
  defp backlog_operations do
    Map.new(Ledger.read!(Operation), &{&1.id, &1})
  end

  @spec backlog_files(Path.t()) :: %{String.t() => binary()}
  defp backlog_files(directory) do
    Map.new(
      [
        :lilly_physical,
        :marshall_ready,
        :porsche_physical,
        :porsche_clone,
        :porsche_relocate,
        :porsche_retry,
        :porsche_cancel
      ],
      fn service ->
        name = "#{service}.json"
        {name, File.read!(Path.join(directory, name))}
      end
    )
  end
end
