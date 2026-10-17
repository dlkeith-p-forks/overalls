defmodule Lilly.Host.PoolReportTest do
  use ExUnit.Case, async: true
  alias Lilly.Host.{Lock, Pool}
  @moduletag :tmp_dir

  test "contended observation reports busy without losing pool identity or held ownership",
       %{tmp_dir: dir} do
    File.chmod!(dir, 0o700)
    id = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    identity = %{backend: :zfs, zpool_guid: "1", dataset_guid: "2", dataset: "tank/lilly"}
    pool = %Pool{id: id, path: dir, filesystem_id: "zfs:1:2", storage: identity}
    {:ok, owner} = Lock.acquire(Path.join(dir, ".lilly-storage"))

    try do
      # A separate caller really contends on the native lock; no mocked ZFS output.
      task = Task.async(fn -> Pool.report(pool) end)
      assert Task.await(task) == %{id: id, busy: true, storage: identity}
      assert Lock.current() == owner
      refute File.exists?(Path.join(dir, ".lilly-zfs"))
    after
      Lock.release(owner)
    end
  end
end
