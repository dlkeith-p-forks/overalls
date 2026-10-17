defmodule Lilly.Transfer.KeyRuntimeTest do
  use ExUnit.Case, async: true
  alias Lilly.Transfer.{Key, KeyRuntime}
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    File.chmod!(root, 0o700)

    command = %{
      id: Lilly.UUID.generate(),
      host_id: Lilly.UUID.generate(),
      placement_id: Lilly.UUID.generate(),
      execution_epoch: 2,
      source_host_id: Lilly.UUID.generate(),
      source_endpoint: %{
        "address" => "source.test",
        "port" => 2222,
        "host_key" => "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 0::256>>)
      }
    }

    %{root: root, command: command}
  end

  test "publication binds the source pin and retries keep the same private key", c do
    assert {:ok, result} = KeyRuntime.prepare(c.root, c.command.host_id, c.command)
    assert Map.keys(result) |> Enum.sort() == [:execution_epoch, :id, :placement_id, :public_key]
    key_path = Path.join([c.root, "transfers", c.command.id, "id_ed25519"])
    private = File.read!(key_path)
    assert {:ok, ^result} = KeyRuntime.prepare(c.root, c.command.host_id, c.command)
    assert File.read!(key_path) == private
    refute JSON.encode!(result) =~ private
    changed = put_in(c.command.source_endpoint["address"], "other.test")
    assert {:error, _} = KeyRuntime.prepare(c.root, c.command.host_id, changed)
    assert {:ok, ^result} = KeyRuntime.prepare(c.root, c.command.host_id, c.command)
  end

  test "a retired key worker cannot crash or replace an already fenced control session" do
    state = %{phase: :fenced, transfer_keys: nil, last_error: :stale_connection}

    assert {:noreply, ^state} =
             Lilly.Control.Runtime.handle_info(
               {:transfer_keys_fenced, self(), :unauthorized},
               state
             )
  end

  test "foreign hosts and peer-selected paths produce no state; retired keys cannot return", c do
    assert {:error, _} = KeyRuntime.prepare(c.root, Lilly.UUID.generate(), c.command)

    assert {:error, _} =
             KeyRuntime.prepare(
               c.root,
               c.command.host_id,
               Map.put(c.command, :path, "/tmp/foreign")
             )

    assert File.ls!(c.root) == []
    assert :ok = Key.retire(c.root, c.command.host_id, c.command.id, c.command.placement_id)
    assert {:error, _} = KeyRuntime.prepare(c.root, c.command.host_id, c.command)
    refute File.exists?(Path.join([c.root, "transfers", c.command.id, "id_ed25519"]))
  end

  test "retirement excludes active transfer locks and permanently erases the credential", c do
    assert {:ok, _} = KeyRuntime.prepare(c.root, c.command.host_id, c.command)

    command =
      c.command
      |> Map.take([:id, :host_id, :placement_id, :execution_epoch])
      |> Map.put(:expires_at, System.system_time(:second) + 180)

    directory = Path.join([c.root, "transfers", command.id])

    for name <- ["receive", "stream"] do
      assert {:ok, lock} = Lilly.Host.Lock.acquire(Path.join(directory, name))

      try do
        task = Task.async(fn -> KeyRuntime.retire(c.root, command.host_id, command) end)
        assert {:error, :key_retirement_unconfirmed} = Task.await(task)
        assert File.exists?(Path.join(directory, "id_ed25519"))
      after
        Lilly.Host.Lock.release(lock)
      end
    end

    assert {:ok, receipt} = KeyRuntime.retire(c.root, command.host_id, command)
    assert receipt == Map.take(command, [:id, :placement_id, :execution_epoch])
    refute File.exists?(Path.join(directory, "id_ed25519"))
    refute File.exists?(Path.join(directory, "id_ed25519.pub"))
    assert {:ok, ^receipt} = KeyRuntime.retire(c.root, command.host_id, command)
    assert {:error, _} = KeyRuntime.prepare(c.root, command.host_id, c.command)
  end

  for held <- ["receive", "stream"] do
    test "cancellation fences the key while #{held} ownership prevents a receipt", c do
      assert {:ok, _} = KeyRuntime.prepare(c.root, c.command.host_id, c.command)

      request =
        c.command
        |> Map.take([:id, :host_id, :placement_id, :execution_epoch])
        |> Map.put(:expires_at, System.system_time(:second) + 180)

      directory = Path.join([c.root, "transfers", request.id])
      assert {:ok, lock} = Lilly.Host.Lock.acquire(Path.join(directory, unquote(held)))

      try do
        task =
          Task.async(fn ->
            Lilly.Transfer.DestinationRevocation.execute(c.root, request.host_id, request)
          end)

        assert {:error, :destination_revocation_unconfirmed} = Task.await(task)
        refute File.exists?(Path.join(directory, "id_ed25519"))
        assert {:error, _} = KeyRuntime.prepare(c.root, request.host_id, c.command)
      after
        Lilly.Host.Lock.release(lock)
      end

      assert {:ok, receipt} =
               Lilly.Transfer.DestinationRevocation.execute(c.root, request.host_id, request)

      assert {:ok, ^receipt} =
               Lilly.Transfer.DestinationRevocation.execute(c.root, request.host_id, request)

      assert receipt == Map.take(request, [:id, :placement_id, :execution_epoch])
      assert {:error, _} = KeyRuntime.prepare(c.root, request.host_id, c.command)
    end
  end

  test "destination cancellation before key generation remains fenced after restart", c do
    request =
      c.command
      |> Map.take([:id, :host_id, :placement_id, :execution_epoch])
      |> Map.put(:expires_at, System.system_time(:second) + 180)

    for bad <- [
          %{request | host_id: Lilly.UUID.generate()},
          %{request | expires_at: System.system_time(:second) - 1},
          Map.put(request, :path, "/foreign")
        ] do
      assert {:error, :destination_revocation_unconfirmed} =
               Lilly.Transfer.DestinationRevocation.execute(c.root, c.command.host_id, bad)

      assert File.ls!(c.root) == []
    end

    assert {:ok, receipt} =
             Lilly.Transfer.DestinationRevocation.execute(c.root, request.host_id, request)

    assert {:ok, ^receipt} =
             Task.async(fn ->
               Lilly.Transfer.DestinationRevocation.execute(c.root, request.host_id, request)
             end)
             |> Task.await()

    assert {:error, _} = KeyRuntime.prepare(c.root, request.host_id, c.command)
    refute File.exists?(Path.join([c.root, "transfers", request.id, "id_ed25519"]))
  end

  test "invalid retirement identity, lease and paths cannot create state", c do
    command =
      c.command
      |> Map.take([:id, :host_id, :placement_id, :execution_epoch])
      |> Map.put(:expires_at, System.system_time(:second) + 180)

    for bad <- [
          Map.put(command, :path, "/tmp/foreign"),
          %{command | expires_at: System.system_time(:second)},
          %{command | expires_at: System.system_time(:second) + 600},
          %{command | host_id: Lilly.UUID.generate()}
        ] do
      assert {:error, _} = KeyRuntime.retire(c.root, command.host_id, bad)
      assert File.ls!(c.root) == []
    end
  end
end
