defmodule Lilly.Transfer.ExporterTest do
  use ExUnit.Case, async: true
  alias Lilly.Host.Lock
  alias Lilly.Transfer.Exporter
  @moduletag :tmp_dir

  # An isolated BEAM models the SSH export subprocess: its stdout is disk data,
  # while native control uses FD 3/4. Only synthetic bytes enter this test runner.
  @worker """
  Logger.configure(level: :none)
  [root, program, mode, ttl | args] = System.argv()
  result = case Lilly.Transfer.Exporter.start(root, {program, args}, String.to_integer(ttl)) do
    {:ok, sender} ->
      File.write!(Path.join(root, "registered"), "ready")
      if mode == "death" do
        ready = fn again ->
          if File.exists?(hd(args)), do: :ok, else: (receive do after 10 -> again.(again) end)
        end
        ready.(ready)
        System.halt(7)
      end
      Lilly.Transfer.Exporter.wait(sender, fn ->
        case mode do
          "revoke" -> :revoke
          "stalled" -> receive do after 1500 -> :ok end
          "renew" ->
            if Process.get(:renewed), do: :ok, else: (Process.put(:renewed, true); {:renew, 2000})
          "invalid" -> {:renew, 300001}
          "malformed" -> Port.command(sender.port, "L0\\n"); :ok
          "wait" -> if File.exists?(Path.join(root, "cancel")), do: :revoke, else: :ok
          _ -> :ok
        end
      end)
    error -> error
  end
  File.write!(Path.join(root, "result"), inspect(result))
  """

  setup %{tmp_dir: root} do
    File.chmod!(root, 0o700)
    hold = Path.join(root, "hold")

    File.write!(
      hold,
      "#!#{executable("sh")}\n\"$2\" \"$3\" &\nprintf '%s %s' \"$$\" \"$!\" > \"$1\"\nwait\n"
    )

    File.chmod!(hold, 0o700)
    %{root: root, hold: hold, stream: Path.join(root, "stream")}
  end

  defp executable(name), do: System.find_executable(name) || raise("missing fixture utility")

  defp worker(root, program, mode, ttl, args \\ []) do
    System.cmd(
      executable("elixir"),
      [
        "--erl",
        "+S 2:2",
        "-pa",
        Path.dirname(:code.which(Exporter)),
        "-pa",
        Path.dirname(:code.which(Overalls.Diagnostics)),
        "-e",
        @worker,
        "--",
        root,
        program,
        mode,
        Integer.to_string(ttl) | args
      ]
    )
  end

  defp held(c, mode, ttl, seconds \\ "30") do
    worker(c.stream, c.hold, mode, ttl, [Path.join(c.root, "pids"), executable("sleep"), seconds])
  end

  defp result(c), do: File.read!(Path.join(c.stream, "result"))

  defp reaped(c) do
    for pid <- c.root |> Path.join("pids") |> File.read!() |> String.split() do
      refute File.exists?("/proc/" <> pid)
    end

    assert {:ok, lock} = Lock.acquire(c.stream)
    assert :ok = Lock.release(lock)
  end

  defp eventually(fun, deadline) do
    case fun.() do
      false ->
        assert System.monotonic_time(:millisecond) < deadline

        receive do
        after
          10 -> eventually(fun, deadline)
        end

      result ->
        result
    end
  end

  test "native stdout is the exact disk stream and control never contaminates it", c do
    {bytes, 0} =
      worker(c.stream, executable("head"), "normal", 5000, ["-c", "1048576", "/dev/zero"])

    assert bytes == :binary.copy(<<0>>, 1_048_576)
    assert result(c) == ":ok"
    assert {:ok, lock} = Lock.acquire(c.stream)
    assert :ok = Lock.release(lock)
  end

  test "revocation kills and reaps both sender and descendant before returning", c do
    assert {"", 0} = held(c, "revoke", 5000)
    assert result(c) == "{:error, :exporter_revoked}"
    reaped(c)
  end

  test "native lease expires even while the BEAM authority checker is stalled", c do
    assert {"", 0} = held(c, "stalled", 500)
    assert result(c) == "{:error, :exporter_expired}"
    reaped(c)
  end

  test "a bounded renewal keeps the sender alive beyond its initial lease", c do
    assert {"", 0} = held(c, "renew", 1000, "1.2")
    assert result(c) == ":ok"
    reaped(c)
  end

  test "invalid renewal and malformed native control revoke rather than extend authority", c do
    for mode <- ["invalid", "malformed"] do
      assert {"", 0} = held(c, mode, 5000)
      assert result(c) == "{:error, :exporter_revoked}"
      reaped(c)
    end
  end

  test "export subprocess death leaves no live sender and preserves its lock inode", c do
    assert {"", 7} = held(c, "death", 5000)
    inode = File.stat!(Path.join(c.stream, "owner.lock")).inode
    deadline = System.monotonic_time(:millisecond) + 5000

    lock =
      eventually(
        fn ->
          case Lock.acquire(c.stream) do
            {:ok, lock} -> lock
            _ -> false
          end
        end,
        deadline
      )

    assert :ok = Lock.release(lock)
    assert File.stat!(Path.join(c.stream, "owner.lock")).inode == inode
    reaped(c)
  end

  test "a second exporter cannot run while the first holds transfer ownership", c do
    task = Task.async(fn -> held(c, "wait", 10_000) end)

    try do
      eventually(
        fn -> File.exists?(Path.join(c.stream, "registered")) end,
        System.monotonic_time(:millisecond) + 5000
      )

      assert {"", 0} = worker(c.stream, executable("true"), "normal", 5000)
      assert result(c) == "{:error, :exporter_busy}"
      File.write!(Path.join(c.stream, "cancel"), "cancel")
      assert {"", 0} = Task.await(task, 5000)
      reaped(c)
    after
      File.write!(Path.join(c.stream, "cancel"), "cancel")
      Task.shutdown(task, 5000)
    end
  end

  test "excessive diagnostics are discarded and cannot produce successful completion", c do
    noisy = Path.join(c.root, "noisy")
    File.write!(noisy, "#!#{executable("sh")}\n#{executable("head")} -c 65537 /dev/zero >&2\n")
    File.chmod!(noisy, 0o700)
    assert {"", 0} = worker(c.stream, noisy, "normal", 5000)
    assert result(c) == "{:error, :exporter_diagnostics_limit}"
  end
end
