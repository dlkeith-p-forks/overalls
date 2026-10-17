defmodule Lilly.Transfer.StreamTest do
  use ExUnit.Case, async: true
  alias Lilly.Host.Lock
  alias Lilly.Transfer.Stream
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.chmod!(dir, 0o700)
    # Trusted local process fixture, never peer-controlled shell text or argv.
    hold = Path.join(dir, "hold")

    File.write!(
      hold,
      "#!#{executable("sh")}\n\"$2\" 60 &\nprintf '%s %s' \"$$\" \"$!\" > \"$1\"\nwait\n"
    )

    File.chmod!(hold, 0o700)
    %{dir: dir, hold: hold, ownership: Path.join(dir, "transfer")}
  end

  defp executable(name), do: System.find_executable(name) || raise("missing fixture utility")
  defp held(c, side), do: {c.hold, [Path.join(c.dir, side), executable("sleep")]}

  defp eventually(function, deadline) do
    case function.() do
      false ->
        assert System.monotonic_time(:millisecond) < deadline

        receive do
        after
          10 -> eventually(function, deadline)
        end

      value ->
        value
    end
  end

  defp deadline, do: System.monotonic_time(:millisecond) + 5000

  defp pids(c) do
    for side <- ["producer", "consumer"],
        pid <- c.dir |> Path.join(side) |> File.read!() |> String.split(),
        do: pid
  end

  # @cc [owner:ghuntley,label:verification;recovery] stream-children-eventually-reaped
  # A native stream completion or caller-death lock release MUST leave every
  # observed child PID absent within five seconds. A transient adopted zombie
  # while PID 1 schedules reaping MAY be observed, but no zombie or live child
  # may satisfy the final assertion.
  defp assert_reaped(pids) do
    await_absence(pids, deadline())

    Enum.each(pids, fn pid ->
      path = "/proc/" <> pid

      if File.exists?(path) do
        case File.read(Path.join(path, "status")) do
          {:ok, status} ->
            state = Regex.run(~r/^State:\s+\S+/m, status) || []
            parent = Regex.run(~r/^PPid:\s+\d+/m, status) || []

            flunk(
              "native stream returned with pid #{pid} still present: #{inspect(state ++ parent)}"
            )

          {:error, :enoent} ->
            :ok

          {:error, reason} ->
            flunk("cannot inspect native stream pid #{pid}: #{inspect(reason)}")
        end
      end
    end)
  end

  defp await_absence(pids, until) do
    if Enum.any?(pids, &File.exists?("/proc/" <> &1)) and
         System.monotonic_time(:millisecond) < until do
      receive do
      after
        10 -> await_absence(pids, until)
      end
    end

    :ok
  end

  test "64 MiB flows through the native pipe without returning bytes to BEAM", c do
    target = Path.join(c.dir, "disk")

    assert :ok =
             Stream.run(
               c.ownership,
               {executable("head"), ["-c", "67108864", "/dev/zero"]},
               {executable("dd"), ["of=" <> target, "bs=65536", "status=none"]},
               10_000
             )

    assert File.stat!(target).size == 67_108_864
    chunk = :binary.copy(<<0>>, 65_536)

    expected =
      Enum.reduce(1..1024, :crypto.hash_init(:sha256), fn _, hash ->
        :crypto.hash_update(hash, chunk)
      end)
      |> :crypto.hash_final()
      |> Base.encode16(case: :lower)

    {actual, 0} = System.cmd(executable("sha256sum"), [target])
    assert String.starts_with?(actual, expected <> " ")
    assert {:ok, port} = Lock.acquire(c.ownership)
    assert :ok = Lock.release(port)
  end

  test "native rate bounds throughput while preserving cancellation", c do
    started = System.monotonic_time(:millisecond)

    assert :ok =
             Stream.run(
               c.ownership,
               {executable("head"), ["-c", "262144", "/dev/zero"]},
               {executable("dd"), ["of=/dev/null", "status=none"]},
               10_000,
               131_072
             )

    assert System.monotonic_time(:millisecond) - started >= 1400

    assert {:error, :stream_timeout} =
             Stream.run(
               c.ownership,
               {executable("head"), ["-c", "1048576", "/dev/zero"]},
               {executable("dd"), ["of=/dev/null", "status=none"]},
               1000,
               1
             )

    assert {:ok, lock} = Lock.acquire(c.ownership)
    assert :ok = Lock.release(lock)
  end

  test "progress reports transport counters with a final exact count", c do
    owner = self()

    assert :ok =
             Stream.run(
               c.ownership,
               {executable("head"), ["-c", "262144", "/dev/zero"]},
               {executable("dd"), ["of=/dev/null", "status=none"]},
               10_000,
               131_072,
               owner
             )

    counts = progress_counts(owner, [])
    assert Enum.any?(counts, &(&1 > 0 and &1 < 262_144))
    assert List.last(counts) == 262_144
    assert counts == Enum.sort(counts)
  end

  defp progress_counts(owner, collected) do
    receive do
      {:lilly_transfer_progress, ^owner, count} -> progress_counts(owner, [count | collected])
    after
      0 -> Enum.reverse(collected)
    end
  end

  test "deadline kills and reaps both process groups before returning", c do
    assert {:error, :stream_timeout} =
             Stream.run(c.ownership, held(c, "producer"), held(c, "consumer"), 1000)

    assert_reaped(pids(c))
    assert {:ok, port} = Lock.acquire(c.ownership)
    assert :ok = Lock.release(port)
  end

  test "owner death revokes work and contention cannot start a second stream", c do
    task =
      Task.async(fn ->
        Stream.run(c.ownership, held(c, "producer"), held(c, "consumer"), 30_000)
      end)

    try do
      eventually(
        fn -> Enum.all?(["producer", "consumer"], &File.exists?(Path.join(c.dir, &1))) end,
        deadline()
      )

      children = pids(c)

      assert {:error, :stream_busy} =
               Stream.run(c.ownership, {executable("true"), []}, {executable("true"), []}, 1000)

      inode = File.stat!(Path.join(c.ownership, "owner.lock")).inode
      Task.shutdown(task, :brutal_kill)

      port =
        eventually(
          fn ->
            case Lock.acquire(c.ownership) do
              {:ok, port} -> port
              {:error, _} -> false
            end
          end,
          deadline()
        )

      try do
        assert_reaped(children)
        assert File.stat!(Path.join(c.ownership, "owner.lock")).inode == inode
      after
        Lock.release(port)
      end
    after
      Task.shutdown(task, :brutal_kill)
    end
  end

  test "producer and consumer failures have closed distinct observations", c do
    assert {:error, :stream_producer_failed} =
             Stream.run(c.ownership, {executable("false"), []}, {executable("cat"), []}, 1000)

    assert {:error, :stream_consumer_failed} =
             Stream.run(
               c.ownership,
               {executable("sleep"), ["60"]},
               {executable("false"), []},
               1000
             )

    assert {:ok, lock} = Lock.acquire(c.ownership)
    assert :ok = Lock.release(lock)
  end

  test "an early successful consumer exit still fails a broken data pipe", c do
    assert {:error, :stream_pipe_failed} =
             Stream.run(
               c.ownership,
               {executable("yes"), ["synthetic"]},
               {executable("true"), []},
               1000
             )

    assert {:ok, lock} = Lock.acquire(c.ownership)
    assert :ok = Lock.release(lock)
  end

  test "diagnostics are discarded and bounded even when a utility exits zero", c do
    # Consumer stdout is diagnostic, never disk data returned to the runtime.
    assert {:error, :stream_diagnostics_limit} =
             Stream.run(
               c.ownership,
               {executable("true"), []},
               {executable("head"), ["-c", "131072", "/dev/zero"]},
               1000
             )
  end

  test "bad frames and a held pool lock fail before launching utilities", c do
    good = {executable("true"), []}

    for bad <- [
          {"relative", []},
          {executable("true"), ["bad\0argument"]},
          {executable("true"), List.duplicate("arg", 128)},
          {executable("true"), [String.duplicate("a", 65_536)]}
        ] do
      assert {:error, :invalid_stream} = Stream.run(c.ownership, bad, good, 1000)
    end

    refute File.exists?(c.ownership)
    {:ok, port} = Lock.acquire(c.dir)

    try do
      assert {:error, :invalid_stream} = Stream.run(c.ownership, good, good, 1000)
      refute File.exists?(c.ownership)
    after
      Lock.release(port)
    end
  end
end
