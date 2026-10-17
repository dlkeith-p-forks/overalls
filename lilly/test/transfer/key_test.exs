defmodule Lilly.Transfer.KeyTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Lilly.Host.{Command, Lock, PrivateFiles}
  alias Lilly.Transfer.Key
  @moduletag :tmp_dir

  setup %{tmp_dir: root} do
    File.chmod!(root, 0o700)
    on_exit(fn -> File.rm_rf!(root) end)

    c = %{
      root: root,
      host: Lilly.UUID.generate(),
      relocation: Lilly.UUID.generate(),
      placement: Lilly.UUID.generate()
    }

    Map.put(c, :directory, Path.join([root, "transfers", c.relocation]))
  end

  test "real OpenSSH key generation is durable, private and stable on retry", c do
    assert {:ok, public} = ensure(c)
    assert String.starts_with?(public, "ssh-ed25519 ")
    assert byte_size(public) == 80
    assert {:ok, ^public} = ensure(c)
    assert Bitwise.band(File.stat!(key_path(c)).mode, 0o777) == 0o600
    assert Bitwise.band(File.stat!(c.directory).mode, 0o777) == 0o700
    assert File.lstat(key_path(c) <> ".pub") == {:error, :enoent}
    journal = c.directory |> Path.join("key.json") |> File.read!() |> JSON.decode!()

    assert journal == %{
             "version" => 3,
             "host_id" => c.host,
             "relocation_id" => c.relocation,
             "placement_id" => c.placement,
             "state" => "ready",
             "public_key" => public,
             "connection" => nil
           }
  end

  test "different relocations receive different keys and cannot rebind identity", c do
    {:ok, first} = ensure(c)
    other = %{c | relocation: Lilly.UUID.generate()}
    assert {:ok, second} = ensure(other)
    refute first == second
    assert {:error, _} = ensure(%{c | host: Lilly.UUID.generate()})
    assert {:error, _} = ensure(%{c | placement: Lilly.UUID.generate()})
    assert {:ok, ^first} = ensure(c)
  end

  test "invalid IDs fail before creating transfer state", c do
    assert {:error, :invalid_transfer_identity} = ensure(%{c | relocation: "../elsewhere"})
    assert File.ls!(c.root) == []
  end

  test "local copy authority requires the existing key and rejects permanent retirement", c do
    assert {:error, _} = Key.ready(c.root, c.host, c.relocation, c.placement)
    refute File.exists?(key_path(c))
    assert {:ok, _} = ensure(c)
    assert :ok = Key.ready(c.root, c.host, c.relocation, c.placement)
    assert {:error, _} = Key.ready(c.root, c.host, c.relocation, Lilly.UUID.generate())
    assert :ok = Key.retire(c.root, c.host, c.relocation, c.placement)
    assert {:error, _} = Key.ready(c.root, c.host, c.relocation, c.placement)
    assert {:error, _} = ensure(c)
  end

  test "interrupted unpublished key generation recovers a partial file", c do
    pending(c)
    File.write!(key_path(c), "interrupted-key")
    File.chmod!(key_path(c), 0o600)
    assert {:ok, public} = ensure(c)
    assert {:ok, ^public} = ensure(c)
  end

  test "an unpublished complete private key is retained after interruption", c do
    pending(c)
    {:ok, lock} = Lock.acquire(c.directory)

    public =
      try do
        {:ok, _} =
          Command.run(:ssh_keygen, ["-q", "-t", "ed25519", "-N", "", "-C", "", "-f", key_path(c)])

        {:ok, output} = Command.run(:ssh_keygen, ["-y", "-f", key_path(c)])
        String.trim_trailing(output, "\n")
      after
        Lock.release(lock)
      end

    assert {:ok, ^public} = ensure(c)
  end

  test "missing or corrupt published keys are never regenerated", c do
    assert {:ok, _} = ensure(c)
    File.write!(key_path(c), "corrupted-key")
    assert {:error, :invalid_transfer_key_state} = ensure(c)
    assert File.read!(key_path(c)) == "corrupted-key"
    File.rm!(key_path(c))
    assert {:error, :invalid_transfer_key_state} = ensure(c)
    refute File.exists?(key_path(c))
  end

  test "a different valid key cannot replace the published key", c do
    {:ok, _} = ensure(c)
    relocation = Lilly.UUID.generate()
    other = %{c | relocation: relocation, directory: Path.join([c.root, "transfers", relocation])}
    {:ok, _} = ensure(other)
    File.cp!(key_path(other), key_path(c))
    assert {:error, :invalid_transfer_key_state} = ensure(c)
  end

  test "unbound or unsafe private files are not adopted or overwritten", c do
    pending(c)
    external = Path.join(c.root, "external")
    File.write!(external, "do-not-touch")
    File.chmod!(external, 0o600)
    File.ln_s!(external, key_path(c))
    assert {:error, _} = ensure(c)
    assert File.read!(external) == "do-not-touch"
    File.rm!(key_path(c))
    File.write!(key_path(c), "unbound")
    File.chmod!(key_path(c), 0o600)
    File.rm!(Path.join(c.directory, "key.json"))
    assert {:error, :invalid_transfer_key_state} = ensure(c)
    assert File.read!(key_path(c)) == "unbound"
  end

  test "retirement removes private material and permanently rejects delayed generation", c do
    {:ok, _} = ensure(c)
    assert :ok = retire(c)
    assert :ok = retire(c)
    refute File.exists?(key_path(c))
    assert {:error, :transfer_key_retired} = ensure(c)
  end

  test "retirement retries erase a key left behind after tombstone publication", c do
    {:ok, _} = ensure(c)
    journal = Path.join(c.directory, "key.json")
    state = journal |> File.read!() |> JSON.decode!() |> Map.put("state", "retired")
    :ok = PrivateFiles.write(c.directory, "key.json", JSON.encode!(state))
    assert {:error, :transfer_key_retired} = ensure(c)
    assert File.exists?(key_path(c))
    assert :ok = retire(c)
    refute File.exists?(key_path(c))
  end

  test "cancellation before generation leaves a tombstone", c do
    assert :ok = retire(c)
    assert {:error, :transfer_key_retired} = ensure(c)
    refute File.exists?(key_path(c))
  end

  test "publication and retirement emit correlated events once without key material", c do
    output =
      capture_log([metadata: [:event, :relocation_id, :placement_id]], fn ->
        assert {:ok, public} = ensure(c)
        assert {:ok, ^public} = ensure(c)
        assert :ok = retire(c)
        assert :ok = retire(c)
      end)

    lines = String.split(output, "\n")

    assert Enum.count(lines, &(&1 =~ "Relocation key created" and &1 =~ c.relocation)) == 1
    assert Enum.count(lines, &(&1 =~ "Relocation key retired" and &1 =~ c.relocation)) == 1
    assert Enum.any?(lines, &(&1 =~ c.relocation and &1 =~ c.placement))

    other = Map.merge(c, %{relocation: Lilly.UUID.generate()})
    other = %{other | directory: Path.join([c.root, "transfers", other.relocation])}
    assert {:ok, _} = ensure(other)
    private = File.read!(key_path(other))
    refute output =~ private
    assert {:error, :transfer_key_retired} = ensure(c)
  end

  defp pending(c) do
    :ok = PrivateFiles.directory(Path.join(c.root, "transfers"))
    :ok = PrivateFiles.directory(c.directory)

    :ok =
      PrivateFiles.write(
        c.directory,
        "key.json",
        JSON.encode!(%{
          "version" => 3,
          "host_id" => c.host,
          "relocation_id" => c.relocation,
          "placement_id" => c.placement,
          "state" => "pending",
          "public_key" => nil,
          "connection" => nil
        })
      )
  end

  defp key_path(c), do: Path.join(c.directory, "id_ed25519")
  defp ensure(c), do: Key.ensure(c.root, c.host, c.relocation, c.placement)
  defp retire(c), do: Key.retire(c.root, c.host, c.relocation, c.placement)
end
