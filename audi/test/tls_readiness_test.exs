defmodule Audi.TLS.ReadinessTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Audi.TLS.Readiness

  setup do
    %{tasks: start_supervised!({Task.Supervisor, max_children: 20})}
  end

  # @cc [owner:ghuntley,label:verification;protocol] audi-readiness-version-halt-history
  # Terminal result from an owned job MUST retire every other job, notify the
  # owner and refuse queued refreshes without reopening authority.
  property "owned version refusal cancels jobs and cannot be reopened by ticks", c do
    check all(count <- member_of([1, 7, 16]), max_runs: 3) do
      parent = self()
      tag = make_ref()

      scheduler =
        pool(c, fn entry, _ ->
          send(parent, {tag, entry.vm_id, self()})

          receive do
            :version_refused -> {:error, :unsupported_version}
            :release -> :ok
          end
        end)

      try do
        entries = for number <- 1..count, do: {%{vm_id: to_string(number)}, number}
        assert :ok = Readiness.refresh(scheduler, entries, now() + 5000)

        jobs =
          for _ <- 1..count do
            assert_receive {^tag, _, pid}
            pid
          end

        send(hd(jobs), :version_refused)
        assert_receive {:control_version_refused, ^scheduler}, 1000
        Enum.each(jobs, &await_dead/1)

        assert {:error, :unsupported_version} =
                 Readiness.refresh(scheduler, entries, now() + 5000)

        for _ <- 1..3, do: send(scheduler, :tick)
        _ = :sys.get_state(scheduler)
        refute_receive {^tag, _, _}, 300
        assert :sys.get_state(scheduler).jobs == %{}
      after
        GenServer.stop(scheduler)
      end
    end
  end

  property "healthy refreshes do not wait for unfinished jobs", c do
    check all(slow_count <- integer(1..8), max_runs: 3) do
      tag = make_ref()
      parent = self()

      work = fn entry, revision ->
        send(parent, {tag, entry.vm_id, self(), revision})
        if entry.vm_id != "healthy", do: receive(do: (:release -> :ok))
      end

      pool = pool(c, work)
      entries = for number <- 1..slow_count, do: {%{vm_id: to_string(number)}, 1}
      :ok = Readiness.refresh(pool, [{%{vm_id: "healthy"}, 2} | entries], now() + 5000)

      slow =
        for number <- 1..slow_count do
          id = to_string(number)
          assert_receive {^tag, ^id, pid, 1}
          pid
        end

      assert_receive {^tag, "healthy", _, 2}
      assert_receive {^tag, "healthy", _, 2}, 2000
      assert Enum.all?(slow, &Process.alive?/1)
      :ok = Readiness.refresh(pool, [], now() + 5000)
      Enum.each(slow, &await_dead/1)
      GenServer.stop(pool)
    end
  end

  property "concurrency stays bounded and each completion admits queued work", c do
    check all(count <- integer(17..40), max_runs: 5) do
      tag = make_ref()
      parent = self()

      pool =
        pool(c, fn entry, _ ->
          send(parent, {tag, entry.vm_id, self()})

          receive do
            :release -> :ok
          end
        end)

      entries = for n <- 1..count, do: {%{vm_id: to_string(n)}, n}
      :ok = Readiness.refresh(pool, entries, now() + 5000)

      running =
        for _ <- 1..16 do
          assert_receive {^tag, id, pid}
          {id, pid}
        end

      refute_receive {^tag, _, _}, 30
      send(elem(hd(running), 1), :release)
      assert_receive {^tag, next_id, next_pid}
      refute next_id in Enum.map(running, &elem(&1, 0))
      :ok = Readiness.refresh(pool, [], now() + 5000)
      Enum.each([next_pid | Enum.map(running, &elem(&1, 1))], &await_dead/1)
      GenServer.stop(pool)
    end
  end

  test "catalog expiry kills jobs even with the scheduler suspended", c do
    parent = self()

    pool =
      pool(c, fn _, _ ->
        send(parent, {:job, self()})

        receive do
          :release -> :ok
        end
      end)

    :ok = Readiness.refresh(pool, [{%{vm_id: "vm"}, 1}], now() + 200)
    assert_receive {:job, job}
    :ok = :sys.suspend(pool)

    try do
      await_dead(job)
    after
      :sys.resume(pool)
    end

    refute_receive {:job, _}, 300
  end

  test "owner death cancels jobs and changed bindings cancel the old revision", c do
    parent = self()

    owner =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    pool =
      pool(
        c,
        fn entry, revision ->
          send(parent, {:job, self(), entry, revision})

          receive do
            :release -> :ok
          end
        end,
        owner
      )

    :ok = Readiness.refresh(pool, [{%{vm_id: "vm", generation: 1}, 11}], now() + 5000)
    assert_receive {:job, old, _, 11}
    :ok = Readiness.refresh(pool, [{%{vm_id: "vm", generation: 2}, 12}], now() + 5000)
    assert_receive {:job, current, %{generation: 2}, 12}
    await_dead(old)
    Process.exit(owner, :kill)
    await_dead(current)
    await_dead(pool)
  end

  defp pool(c, work, owner \\ self()),
    do: start_supervised!({Readiness, owner: owner, tasks: c.tasks, work: work}, id: make_ref())

  defp await_dead(pid) do
    ref = Process.monitor(pid)
    assert_receive {:DOWN, ^ref, :process, ^pid, _}, 1500
  end

  defp now, do: System.monotonic_time(:millisecond)
end
