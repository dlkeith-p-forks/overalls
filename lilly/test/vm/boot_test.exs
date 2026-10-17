defmodule Lilly.VM.BootTest do
  use ExUnit.Case, async: true
  alias Lilly.Host.{Lock, PrivateFiles}
  alias Lilly.VM.{Boot, Intent}
  @placement "11111111-1111-4111-8111-111111111111"
  @other "22222222-2222-4222-8222-222222222222"
  @moduletag :tmp_dir

  setup %{tmp_dir: dir} do
    File.chmod!(dir, 0o700)
    :ok
  end

  defp locked(dir, callback) do
    {:ok, port} = Lock.acquire(Path.join(dir, "lock"))

    try do
      callback.()
    after
      Lock.release(port)
    end
  end

  test "prelaunch retries retain a durable challenge and newer boots rotate it", %{tmp_dir: dir} do
    locked(dir, fn ->
      assert {:ok, intent} = Intent.set(dir, @placement, {1, 1}, :running)
      assert {:ok, first} = Boot.prepare(dir, intent)
      assert {:ok, ^first} = Boot.read(dir)
      assert {:ok, ^first} = Boot.prepare(dir, intent)
      assert byte_size(first.boot_challenge) == 64
      assert {:ok, next} = Intent.set(dir, @placement, {1, 2}, :running)
      assert {:ok, second} = Boot.prepare(dir, next)
      refute first.boot_challenge == second.boot_challenge
      assert {:ok, next_epoch} = Intent.set(dir, @placement, {2, 1}, :running)
      assert {:ok, third} = Boot.prepare(dir, next_epoch)
      refute third.boot_challenge in [first.boot_challenge, second.boot_challenge]
      assert Boot.expectation(third) == Map.delete(third, :generation)
    end)
  end

  test "a caller without ownership cannot publish boot state", %{tmp_dir: dir} do
    assert {:ok, intent} = Intent.set(dir, @placement, {1, 1}, :running)
    assert {:error, :boot_identity_unconfirmed} = Boot.prepare(dir, intent)
    assert {:ok, nil} = Boot.read(dir)
  end

  test "old or stopped authority cannot replace the current boot", %{tmp_dir: dir} do
    locked(dir, fn ->
      {:ok, old} = Intent.set(dir, @placement, {1, 1}, :running)
      {:ok, current} = Intent.set(dir, @placement, {1, 2}, :running)
      {:ok, boot} = Boot.prepare(dir, current)
      assert {:error, :boot_identity_unconfirmed} = Boot.prepare(dir, old)
      {:ok, stopped} = Intent.set(dir, @placement, {1, 3}, :stopped)
      assert {:error, :boot_identity_unconfirmed} = Boot.prepare(dir, stopped)
      assert {:ok, ^boot} = Boot.read(dir)
    end)
  end

  test "corrupt or unsafe existing state is never replaced", %{tmp_dir: dir} do
    locked(dir, fn ->
      {:ok, intent} = Intent.set(dir, @placement, {1, 1}, :running)
      :ok = PrivateFiles.write(dir, "boot.json", "broken")
      assert {:error, :boot_identity_unconfirmed} = Boot.prepare(dir, intent)
      assert File.read!(Path.join(dir, "boot.json")) == "broken"
      File.rm!(Path.join(dir, "boot.json"))
      File.ln_s!(Path.join(dir, "intent.bin"), Path.join(dir, "boot.json"))
      assert {:error, :boot_identity_unconfirmed} = Boot.prepare(dir, intent)
    end)
  end

  test "persisted boot state cannot rebind a placement or regress its revision", %{tmp_dir: dir} do
    locked(dir, fn ->
      {:ok, intent} = Intent.set(dir, @placement, {1, 1}, :running)
      {:ok, _boot} = Boot.prepare(dir, intent)
      original = File.read!(Path.join(dir, "boot.json")) |> JSON.decode!()

      for change <- [%{"placement_id" => @other}, %{"execution_epoch" => 2}, %{"generation" => 2}] do
        body = JSON.encode!(Map.merge(original, change))
        :ok = PrivateFiles.write(dir, "boot.json", body)
        assert {:error, :boot_identity_unconfirmed} = Boot.prepare(dir, intent)
        assert File.read!(Path.join(dir, "boot.json")) == body
      end
    end)
  end

  test "current boot observation requires all authority fields and running intent", %{
    tmp_dir: dir
  } do
    locked(dir, fn ->
      {:ok, intent} = Intent.set(dir, @placement, {2, 3}, :running)
      assert {:error, :boot_identity_unconfirmed} = Boot.current(dir, @placement, {2, 3})
      {:ok, boot} = Boot.prepare(dir, intent)
      assert {:ok, ^boot} = Boot.current(dir, @placement, {2, 3})

      for {placement, revision} <- [
            {@other, {2, 3}},
            {@placement, {1, 3}},
            {@placement, {2, 2}},
            {@placement, {2, nil}}
          ] do
        assert {:error, :boot_identity_unconfirmed} = Boot.current(dir, placement, revision)
      end

      {:ok, _} = Intent.set(dir, @placement, {2, 3}, :failed)
      assert {:error, :boot_identity_unconfirmed} = Boot.current(dir, @placement, {2, 3})
    end)
  end
end
