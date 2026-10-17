defmodule Lilly.ZFSFixture do
  @moduledoc "Owned disposable datasets for trusted, opt-in root test harnesses."

  # @cc [owner:ghuntley,label:security] disposable-zfs-fixture-ownership
  # Fixtures MUST create only a new UUID-named child of an explicitly supplied
  # test parent. Cleanup MUST match the recorded GUID, mount and owner and use
  # nonrecursive destruction after guest cleanup; failures retain the fixture.
  @spec create(String.t(), Path.t(), String.t()) :: map()
  def create(parent, path, owner) do
    true = OverallsProtocol.uuid?(owner)
    name = parent <> "/overalls-test-" <> owner

    true =
      OverallsProtocol.Storage.valid_identity?(%{
        backend: :zfs,
        zpool_guid: "1",
        dataset_guid: "1",
        dataset: name
      })

    {:error, :enoent} = File.lstat(path)
    "filesystem" = run(["get", "-Hpo", "value", "type", parent])

    run([
      "create",
      "-o",
      "mountpoint=" <> path,
      "-o",
      "compression=lz4",
      "-o",
      "reservation=none",
      "-o",
      "refreservation=none",
      "-o",
      "dedup=off",
      "-o",
      "sync=standard",
      "-o",
      "readonly=off",
      "-o",
      "canmount=on",
      "-o",
      "lilly-test:owner=" <> owner,
      name
    ])

    File.chmod!(path, 0o700)
    {:ok, identity} = Lilly.Host.Pool.inspect_path(path)

    %{
      "dataset" => name,
      "dataset_guid" => identity.storage.dataset_guid,
      "path" => path,
      "owner" => owner
    }
  end

  @spec destroy(map()) :: :ok
  def destroy(%{"dataset" => name, "dataset_guid" => guid, "path" => path, "owner" => owner}) do
    true = OverallsProtocol.uuid?(owner)
    true = String.ends_with?(name, "/overalls-test-" <> owner)
    ^owner = run(["get", "-Hpo", "value", "lilly-test:owner", name])
    ^guid = run(["get", "-Hpo", "value", "guid", name])
    ^path = run(["get", "-Hpo", "value", "mountpoint", name])
    run(["destroy", name])
    :ok
  end

  defp run(arguments) do
    case System.cmd("zfs", arguments, stderr_to_stdout: true) do
      {output, 0} -> String.trim(output)
      _ -> raise "ZFS fixture command failed; preserve owned state"
    end
  end
end
