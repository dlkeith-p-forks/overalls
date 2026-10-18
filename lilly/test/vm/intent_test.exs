defmodule Lilly.VM.IntentTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Host.Lock
  alias Lilly.VM.Intent
  @placement "11111111-1111-4111-8111-111111111111"
  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    File.chmod!(directory, 0o700)
    :ok
  end

  @tag :hegel

  test "arbitrary older generations cannot reverse the launch fence", %{tmp_dir: dir} do
    check all(generation <- integer(1..9_223_372_036_854_775_800), max_runs: 40) do
      directory = Path.join(dir, Integer.to_string(System.unique_integer([:positive])))
      File.mkdir!(directory)
      File.chmod!(directory, 0o700)
      assert {:ok, _} = Intent.set(directory, @placement, {1, generation}, :running)
      assert {"launched", 0} = launch(directory, generation, "printf", ["launched"])
      assert {:ok, stopped} = Intent.set(directory, @placement, {1, generation + 1}, :stopped)

      assert {:error, :stale_generation} =
               Intent.set(directory, @placement, {1, generation}, :running)

      assert {"", 75} = launch(directory, generation, "printf", ["forbidden"])
      assert {"", 75} = launch(directory, generation + 1, "printf", ["forbidden"])
      assert {:ok, ^stopped} = Intent.read(directory)
    end
  end

  test "failure is terminal for its generation; deletion is terminal for the VM", %{tmp_dir: dir} do
    assert {:ok, _} = Intent.set(dir, @placement, {1, 1}, :running)
    assert {:ok, failed} = Intent.set(dir, @placement, {1, 1}, :failed)
    assert {:ok, ^failed} = Intent.set(dir, @placement, {1, 1}, :failed)
    assert {:error, :generation_conflict} = Intent.set(dir, @placement, {1, 1}, :running)
    assert {"", 75} = launch(dir, 1, "true", [])
    assert {:ok, _} = Intent.set(dir, @placement, {1, 2}, :running)
    assert {"", 0} = launch(dir, 2, "true", [])
    assert {:ok, _} = Intent.set(dir, @placement, {1, 3}, :deleted)
    assert {:error, :vm_deleted} = Intent.set(dir, @placement, {1, 4}, :running)
    assert {"", 75} = launch(dir, 2, "true", [])
  end

  test "a queued launcher reads the newer intent only after the exclusive writer releases", %{
    tmp_dir: dir
  } do
    assert {:ok, _} = Intent.set(dir, @placement, {1, 1}, :running)
    {:ok, port} = Lock.acquire(Intent.lock_directory(dir))
    parent = self()

    start_supervised!({Task, fn -> send(parent, {:launch, launch(dir, 1, "true", [])}) end})

    try do
      # The writer's lock deliberately pauses any launcher until after this durable change.
      assert :ok =
               Lilly.Host.PrivateFiles.write(
                 dir,
                 "intent.bin",
                 <<@placement::binary, 1::64, 2::64, 0>>
               )

      refute_receive {:launch, _}, 20
    after
      Lock.release(port)
    end

    assert_receive {:launch, {"", 75}}, 2000
  end

  test "a launcher retains shared ownership across exec until its child exits", %{tmp_dir: dir} do
    assert {:ok, _} = Intent.set(dir, @placement, {1, 1}, :running)
    fifo = Path.join(dir, "fifo")
    {_, 0} = System.cmd("mkfifo", [fifo])
    parent = self()

    caller =
      start_supervised!({Task, fn -> send(parent, {:done, launch(dir, 1, "cat", [fifo])}) end})

    monitor = Process.monitor(caller)
    await_lock_conflict(Intent.lock_directory(dir), System.monotonic_time(:millisecond) + 2000)
    assert {:error, :host_already_owned} = Intent.set(dir, @placement, {1, 2}, :stopped)
    File.write!(fifo, "done")
    assert_receive {:done, {"done", 0}}, 2000
    assert_receive {:DOWN, ^monitor, :process, ^caller, :normal}, 2000
    assert {:ok, _} = Intent.set(dir, @placement, {1, 2}, :stopped)
  end

  test "corrupt, public or linked intent cannot authorize a launch", %{tmp_dir: dir} do
    assert {:ok, _} = Intent.set(dir, @placement, {1, 1}, :running)
    path = Intent.path(dir)
    File.chmod!(path, 0o644)
    assert {"", 74} = launch(dir, 1, "true", [])
    assert {:error, :invalid_launch_intent} = Intent.set(dir, @placement, {1, 2}, :running)
    File.chmod!(path, 0o600)
    File.ln!(path, Path.join(dir, "alias"))
    assert {"", 74} = launch(dir, 1, "true", [])
    File.rm!(Path.join(dir, "alias"))
    File.write!(path, <<1::64, 1, 1>>)
    assert {"", 74} = launch(dir, 1, "true", [])
    File.rm!(path)
    File.ln_s!("missing", path)
    assert {"", 74} = launch(dir, 1, "true", [])
  end

  test "native guard rejects stale epochs and another placement", %{tmp_dir: dir} do
    assert {:ok, _} = Intent.set(dir, @placement, {1, 100}, :running)
    assert {:ok, renewed} = Intent.set(dir, @placement, {2, 1}, :running)
    assert {:error, :stale_generation} = Intent.set(dir, @placement, {1, 1000}, :running)
    assert {:ok, ^renewed} = Intent.read(dir)
    assert {"", 75} = launch(dir, 100, "true", [])

    run = fn placement, epoch, generation ->
      System.cmd("lilly-launch-guard", [
        Intent.lock_path(dir),
        Intent.path(dir),
        placement,
        epoch,
        generation,
        System.find_executable("true")
      ])
    end

    assert {"", 0} = run.(@placement, "2", "1")
    assert {"", 75} = run.(Lilly.UUID.generate(), "2", "1")
    assert {"", 64} = run.(@placement, "0", "1")
    assert {"", 64} = run.(@placement, "9223372036854775808", "1")

    assert {:error, :placement_identity_conflict} =
             Intent.set(dir, Lilly.UUID.generate(), {3, 1}, :running)

    assert {:ok, _} = Intent.set(dir, @placement, {2, 2}, :deleted)
    assert {:error, :vm_deleted} = Intent.set(dir, @placement, {3, 1}, :running)
  end

  defp launch(dir, generation, executable, args) do
    System.cmd("lilly-launch-guard", [
      Intent.lock_path(dir),
      Intent.path(dir),
      @placement,
      "1",
      to_string(generation),
      System.find_executable(executable) | args
    ])
  end

  defp await_lock_conflict(path, deadline) do
    case Lock.acquire(path) do
      {:error, :host_already_owned} ->
        :ok

      {:ok, port} ->
        Lock.release(port)
        assert System.monotonic_time(:millisecond) < deadline

        receive do
        after
          10 -> await_lock_conflict(path, deadline)
        end
    end
  end
end
