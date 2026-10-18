defmodule Lilly.Host.LockTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Host.Lock
  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    File.chmod!(directory, 0o700)
    :ok
  end

  @tag :hegel
  test "bounded acquisition waits for the same native inode and retains exclusive ownership", c do
    Hegel.check(
      fn ->
        budget = draw("budget", member_of([1000, 2000]))
        delay = draw("delay", integer(div(budget, 4)..div(budget, 3)))
        {:ok, owner} = Lock.acquire(c.tmp_dir)
        inode = File.stat!(Path.join(c.tmp_dir, "owner.lock")).inode
        parent = self()
        tag = make_ref()

        worker =
          Task.async(fn ->
            send(parent, {tag, :waiting})

            with {:ok, successor} <- Lock.acquire(c.tmp_dir, budget) do
              try do
                assert Lock.current() == successor
                assert {:error, :host_already_owned} = Lock.acquire(c.tmp_dir, 0)
                send(parent, {tag, :acquired})
                :acquired
              after
                Lock.release(successor)
              end
            end
          end)

        try do
          assert_receive {^tag, :waiting}
          refute_receive {^tag, :acquired}, delay
          assert :ok = Lock.release(owner)
          assert Task.await(worker, 5000) == :acquired
          assert_receive {^tag, :acquired}
          assert File.stat!(Path.join(c.tmp_dir, "owner.lock")).inode == inode
        after
          Task.shutdown(worker, :brutal_kill)
          if Lock.held?(owner), do: Lock.release(owner)
        end
      end,
      test_cases: 100
    )
  end

  test "persistent contention expires without taking or replacing ownership", c do
    {:ok, owner} = Lock.acquire(c.tmp_dir)
    inode = File.stat!(Path.join(c.tmp_dir, "owner.lock")).inode

    try do
      started = System.monotonic_time(:millisecond)
      worker = Task.async(fn -> Lock.acquire(c.tmp_dir, 1000) end)
      assert Task.await(worker, 5000) == {:error, :host_already_owned}
      elapsed = System.monotonic_time(:millisecond) - started
      assert elapsed >= 1000 and elapsed < 3000
      assert Lock.current() == owner
      assert Lock.held?(owner)
      assert File.stat!(Path.join(c.tmp_dir, "owner.lock")).inode == inode
    after
      Lock.release(owner)
    end
  end

  test "cancelled acquisition cannot obtain later ownership", c do
    {:ok, owner} = Lock.acquire(c.tmp_dir)
    worker = Task.async(fn -> Lock.acquire(c.tmp_dir, 2000) end)

    try do
      assert Task.yield(worker, 30) == nil
      Task.shutdown(worker, :brutal_kill)
      assert :ok = Lock.release(owner)
      assert {:ok, successor} = Lock.acquire(c.tmp_dir, 2000)
      assert :ok = Lock.release(successor)
    after
      Task.shutdown(worker, :brutal_kill)
      if Lock.held?(owner), do: Lock.release(owner)
    end
  end

  test "unavailable ownership does not spend the contention retry window", c do
    path = Path.join(c.tmp_dir, "not-a-directory")
    File.write!(path, "retained")
    started = System.monotonic_time(:millisecond)
    assert {:error, :host_lock_unavailable} = Lock.acquire(path, 2000)
    assert System.monotonic_time(:millisecond) - started < 1000
    assert File.read!(path) == "retained"
    assert Lock.current() == nil
  end

  test "native inode rejection is unavailable rather than retryable contention", c do
    path = Path.join(c.tmp_dir, "owner.lock")
    File.write!(path, "retained")
    File.chmod!(path, 0o666)
    inode = File.stat!(path).inode
    started = System.monotonic_time(:millisecond)
    assert {:error, :host_lock_unavailable} = Lock.acquire(c.tmp_dir, 2000)
    assert System.monotonic_time(:millisecond) - started < 1000
    assert File.stat!(path).inode == inode
    assert File.read!(path) == "retained"
    assert Lock.current() == nil
  end

  # @cc [owner:ghuntley,label:verification;recovery] holder-death-kills-leased-command
  # A holder that dies with a utility blocked under its lease MUST lose the
  # lease only after hostd killed that utility: the utility inherits the lock
  # descriptor, so a surviving utility would keep the successor contended.
  test "a holder's death kills its leased command before the lease frees", c do
    fifo = Path.join(c.tmp_dir, "blocked-source")
    parent = self()

    holder =
      spawn(fn ->
        {:ok, _lease} = Lock.acquire(c.tmp_dir)
        {:ok, _} = Lilly.Host.Command.run(:mkfifo, ["--mode=0600", "--", fifo])
        send(parent, :blocked)
        Lilly.Host.Command.run(:cp, ["--", fifo, Path.join(c.tmp_dir, "target")], 60_000)
      end)

    assert_receive :blocked, 5000
    Process.sleep(200)
    assert {:error, :host_already_owned} = Lock.acquire(c.tmp_dir)
    Process.exit(holder, :kill)
    started = System.monotonic_time(:millisecond)
    assert {:ok, successor} = Lock.acquire(c.tmp_dir, 2000)
    assert System.monotonic_time(:millisecond) - started < 2000
    assert :ok = Lock.release(successor)
  end

  # @cc [owner:ghuntley,label:verification;concurrency] waiters-granted-in-arrival-order
  # Exclusive waiters queued behind a held lease MUST be granted in the order
  # they reached hostd's queue, with no caller-side polling.
  test "queued waiters are granted in arrival order", c do
    {:ok, owner} = Lock.acquire(c.tmp_dir)
    parent = self()

    workers =
      for index <- 1..4 do
        worker =
          Task.async(fn ->
            {:ok, lease} = Lock.await(c.tmp_dir, 10_000)
            send(parent, {:granted, index})
            Process.sleep(30)
            Lock.release(lease)
          end)

        Process.sleep(40)
        worker
      end

    assert :ok = Lock.release(owner)
    Enum.each(workers, &Task.await(&1, 15_000))
    order = for _ <- 1..4, do: receive(do: ({:granted, index} -> index))
    assert order == [1, 2, 3, 4]
  end
end
