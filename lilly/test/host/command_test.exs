defmodule Lilly.Host.CommandTest do
  # CaptureLog observes the shared Logger stream; isolate silence/redaction checks.
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  alias Lilly.Host.{Command, Lock}
  @moduletag :tmp_dir
  @metadata [:event, :utility, :reason, :duration_ms, :lease_id]

  setup %{tmp_dir: directory} do
    File.chmod!(directory, 0o700)
    file = Path.join(directory, "input")
    File.write!(file, "fixture")
    {:ok, owner} = Lock.acquire(directory)
    %{directory: directory, fixture_path: file, owner: owner}
  end

  @tag :hegel
  test "bounded utility failures never log private arguments or output", c do
    Hegel.check(
      fn ->
        bytes = draw("bytes", binary(min_length: 1, max_length: 64))
        secret = "private-utility-" <> Base.encode16(bytes)
        format = String.duplicate(secret, div(20_000, byte_size(secret)) + 1)

        log =
          ExUnit.CaptureLog.capture_log([metadata: @metadata], fn ->
            stdout =
              ExUnit.CaptureIO.capture_io(fn ->
                assert {:error, :command_output_limit} =
                         Command.run(:stat, [
                           "--printf",
                           format,
                           "--" | List.duplicate(c.fixture_path, 4)
                         ])
              end)

            assert stdout == ""
          end)

        assert log =~ "lilly.utility_unconfirmed"
        assert log =~ "utility=stat"
        assert log =~ "command_output_limit"
        assert log =~ "lease_id=#{c.owner.id}"
        assert log =~ "duration_ms="
        refute log =~ secret
        refute log =~ c.fixture_path
        assert Lock.current() == c.owner
        assert {:ok, ^secret} = Command.run(:stat, ["--printf", secret, "--", c.fixture_path])
      end,
      test_cases: 100
    )

    assert :ok = Lock.release(c.owner)
  end

  test "a native timeout identifies the utility and retains the lock", c do
    fifo = Path.join(c.directory, "private-source")
    target = Path.join(c.directory, "private-destination")
    assert {:ok, _} = Command.run(:mkfifo, ["--mode=0600", "--", fifo])

    log =
      ExUnit.CaptureLog.capture_log([metadata: @metadata], fn ->
        assert {:error, :command_timeout} = Command.run(:cp, ["--", fifo, target], 1000)
      end)

    assert log =~ "lilly.utility_unconfirmed"
    assert log =~ "utility=cp"
    assert log =~ "command_timeout"
    refute log =~ fifo
    refute log =~ target
    assert Lock.current() == c.owner
    assert {:error, :host_already_owned} = Lock.acquire(c.directory)
    assert {:ok, _} = Command.run(:stat, ["--", c.fixture_path])
    assert :ok = Lock.release(c.owner)
  end

  test "only image copies and flushes may use a deadline beyond ten minutes", c do
    for name <- [:cp, :stat] do
      assert_raise FunctionClauseError, fn ->
        Command.run(name, ["--", c.fixture_path], 600_001)
      end
    end

    assert_raise FunctionClauseError, fn ->
      Command.run(:image_copy, ["auto", c.fixture_path, c.fixture_path, "7"], 14_400_001)
    end

    assert {:ok, _} = Command.run(:sync, ["--", c.fixture_path], 14_400_000)

    # hostd accepts the same 4 h bound for any utility under a lease.
    assert {:ok, _} =
             Lilly.Host.Hostd.run(
               c.owner.session,
               c.owner.id,
               :stat,
               ["--", c.fixture_path],
               14_400_000,
               65_536
             )

    assert Lock.current() == c.owner
    assert :ok = Lock.release(c.owner)
  end

  test "successful utility output and ordinary nonzero exits stay silent", c do
    log =
      ExUnit.CaptureLog.capture_log(fn ->
        assert {:ok, "private-success"} =
                 Command.run(:stat, ["--printf", "private-success", "--", c.fixture_path])

        assert {:error, :command_failed} =
                 Command.run(:stat, ["--", Path.join(c.directory, "private-missing")])
      end)

    refute log =~ "lilly.utility_unconfirmed"

    assert :ok = Lock.release(c.owner)
  end
end
