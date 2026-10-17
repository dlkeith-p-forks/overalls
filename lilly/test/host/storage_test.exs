defmodule Lilly.Host.StorageTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Host.{Lock, Pool, Storage}
  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    File.chmod!(directory, 0o700)

    pool = %Pool{
      id: "11111111-1111-4111-8111-111111111111",
      path: directory,
      filesystem_id: "zfs:1:2"
    }

    %{pool: pool, lock_dir: Path.join(directory, ".lilly-storage")}
  end

  test "brief native contention permits one protected effect after release", c do
    check all(delay <- integer(20..80), failure <- boolean(), max_runs: 12) do
      {:ok, owner} = Lock.acquire(c.lock_dir)
      parent = self()
      tag = make_ref()

      worker =
        Task.async(fn ->
          send(parent, {tag, :waiting})

          Storage.locked(
            c.pool,
            fn ->
              assert is_struct(Lock.current(), Lilly.Host.Lease)
              assert {:error, :host_already_owned} = Lock.acquire(c.lock_dir)
              send(parent, {tag, :effect})
              if failure, do: {:error, :storage_busy}, else: :done
            end,
            2000
          )
        end)

      try do
        assert_receive {^tag, :waiting}
        refute_receive {^tag, :effect}, delay
        assert :ok = Lock.release(owner)
        assert Task.await(worker, 5000) == if(failure, do: {:error, :storage_busy}, else: :done)
        assert_receive {^tag, :effect}
        refute_receive {^tag, :effect}, 0
      after
        Task.shutdown(worker, :brutal_kill)
        if Lock.held?(owner), do: Lock.release(owner)
      end

      {:ok, successor} = Lock.acquire(c.lock_dir)
      assert :ok = Lock.release(successor)
    end
  end

  test "persistent contention is bounded and never invokes the effect", c do
    {:ok, owner} = Lock.acquire(c.lock_dir)
    parent = self()

    try do
      for window <- [0, 60] do
        started = System.monotonic_time(:millisecond)

        result =
          Task.async(fn -> Storage.locked(c.pool, fn -> send(parent, :forbidden) end, window) end)
          |> Task.await(5000)

        elapsed = System.monotonic_time(:millisecond) - started
        assert result == {:error, :storage_busy}
        assert elapsed < 3000
        if window > 0, do: assert(elapsed >= window)
        refute_receive :forbidden, 0
      end

      assert Lock.current() == owner
    after
      Lock.release(owner)
    end
  end

  test "exceptions are not replayed and release native ownership", c do
    assert_raise RuntimeError, "isolated failure", fn ->
      Storage.locked(c.pool, fn -> raise "isolated failure" end, 2000)
    end

    {:ok, successor} = Lock.acquire(c.lock_dir)
    assert :ok = Lock.release(successor)
  end

  test "cancelled waiters cannot run after the original owner releases", c do
    {:ok, owner} = Lock.acquire(c.lock_dir)
    parent = self()

    worker =
      Task.async(fn -> Storage.locked(c.pool, fn -> send(parent, :forbidden) end, 2000) end)

    refute_receive :forbidden, 30
    Task.shutdown(worker, :brutal_kill)
    assert :ok = Lock.release(owner)
    refute_receive :forbidden, 50
    {:ok, successor} = Lock.acquire(c.lock_dir)
    assert :ok = Lock.release(successor)
  end

  test "a mutation waits through transient contention and executes under the same native lock",
       c do
    {:ok, owner} = Lock.acquire(c.lock_dir)
    inode = File.stat!(Path.join(c.lock_dir, "owner.lock")).inode

    try do
      task =
        Task.async(fn ->
          Storage.locked(c.pool, fn ->
            assert is_struct(Lock.current(), Lilly.Host.Lease)
            contender = Task.async(fn -> Lock.acquire(c.lock_dir) end)
            assert {:error, :host_already_owned} = Task.await(contender)
            :completed
          end)
        end)

      assert Task.yield(task, 100) == nil
      assert :ok = Lock.release(owner)
      assert Task.await(task) == :completed
      assert File.stat!(Path.join(c.lock_dir, "owner.lock")).inode == inode
      assert {:ok, next} = Lock.acquire(c.lock_dir)
      assert :ok = Lock.release(next)
    after
      Lock.release(owner)
    end
  end

  test "persistent contention returns busy without executing or replacing ownership", c do
    {:ok, owner} = Lock.acquire(c.lock_dir)

    try do
      task =
        Task.async(fn ->
          Storage.locked(c.pool, fn -> flunk("executed without ownership") end)
        end)

      assert Task.await(task) == {:error, :storage_busy}
      assert Lock.current() == owner
      assert Lock.held?(owner)
    after
      Lock.release(owner)
    end
  end

  test "callback failure releases ownership and is never retried", c do
    parent = self()

    assert {:error, :storage_busy} =
             Storage.locked(c.pool, fn ->
               send(parent, :called)
               {:error, :storage_busy}
             end)

    assert_receive :called
    refute_receive :called

    assert_raise RuntimeError, "fixture failure", fn ->
      Storage.locked(c.pool, fn -> raise "fixture failure" end)
    end

    assert {:ok, owner} = Lock.acquire(c.lock_dir)
    assert :ok = Lock.release(owner)
  end

  # @cc [owner:ghuntley,label:verification;concurrency] burst-drains-without-busy
  # A burst of create-path sections longer than the old one-second window MUST
  # all run, one at a time, without any storage_busy result (ADR-0176).
  test "a burst of create sections drains through turns without storage_busy", c do
    parent = self()

    results =
      for index <- 1..10 do
        Task.async(fn ->
          Storage.locked(
            c.pool,
            fn ->
              send(parent, {:enter, index})
              Process.sleep(150)
              send(parent, {:exit, index})
              {:done, index}
            end,
            30_000,
            :prepare
          )
        end)
      end
      |> Task.await_many(30_000)

    assert Enum.sort(results) == Enum.map(1..10, &{:done, &1})

    events =
      for _ <- 1..20 do
        assert_receive {kind, index} when kind in [:enter, :exit], 1000
        {kind, index}
      end

    # Strictly alternating enter/exit of the same caller: never two inside.
    assert events
           |> Enum.chunk_every(2)
           |> Enum.all?(fn [{:enter, a}, {:exit, b}] -> a == b end)
  end

  # @cc [owner:ghuntley,label:verification;concurrency] combined-batches-answer-each-item
  # Overlapping combine/5 callers MUST each receive exactly the result computed
  # for their own item, batches MUST run one at a time under the pool lock, and
  # queued callers MUST be combined into batches of more than one item.
  test "combined callers each get their own result from exclusive batches", c do
    check all(count <- integer(2..12), max_runs: 8) do
      parent = self()

      batch = fn items ->
        assert is_struct(Lock.current(), Lilly.Host.Lease)
        send(parent, {:batch, self(), length(items)})
        Process.sleep(40)
        send(parent, {:batch_done, self()})
        Enum.map(items, &{:result, &1})
      end

      results =
        for index <- 1..count do
          Task.async(fn -> Storage.combine(c.pool, :prepare, index, batch, 30_000) end)
        end
        |> Task.await_many(30_000)

      assert results == Enum.map(1..count, &{:result, &1})

      sizes = collect_batches([], nil)
      assert Enum.sum(sizes) == count
      assert Enum.all?(sizes, &(&1 in 1..16))
      if count > 2, do: assert(Enum.any?(sizes, &(&1 > 1)))
    end
  end

  # Batches never overlap: each start is followed by its own end.
  defp collect_batches(sizes, open) do
    receive do
      {:batch, pid, size} ->
        assert open == nil
        collect_batches([size | sizes], pid)

      {:batch_done, pid} ->
        assert open == pid
        collect_batches(sizes, nil)
    after
      200 -> Enum.reverse(sizes)
    end
  end

  test "slow and contended pool sections are diagnosed; fast ones are silent", c do
    metadata = [:event, :pool_id, :kind, :outcome, :wait_ms, :hold_ms]
    pool = %{c.pool | id: "22222222-2222-4222-8222-222222222222"}

    fast =
      ExUnit.CaptureLog.capture_log([metadata: metadata], fn ->
        assert :fast = Storage.locked(pool, fn -> :fast end, 0, :prepare)
      end)

    refute fast =~ pool.id

    slow =
      ExUnit.CaptureLog.capture_log([metadata: metadata], fn ->
        assert :slow = Storage.locked(pool, fn -> Process.sleep(550) && :slow end, 0, :ready)
      end)

    # The capture is global: keep only this pool's lines (other tests run async).
    slow = slow |> String.split("\n") |> Enum.filter(&(&1 =~ pool.id)) |> Enum.join("\n")
    assert slow =~ "lilly.pool_section"
    assert slow =~ "kind=ready"
    assert slow =~ "outcome=acquired"
    assert [_, hold] = Regex.run(~r/hold_ms=(\d+)/, slow)
    assert String.to_integer(hold) >= 500

    {:ok, owner} = Lock.acquire(c.lock_dir)

    busy =
      try do
        ExUnit.CaptureLog.capture_log([metadata: metadata], fn ->
          assert {:error, :storage_busy} =
                   Task.async(fn -> Storage.locked(pool, fn -> :forbidden end, 0, :delete) end)
                   |> Task.await(5000)
        end)
      after
        Lock.release(owner)
      end

    assert busy =~ "kind=delete"
    assert busy =~ "outcome=busy"
    assert busy =~ "hold_ms=0"
  end
end
