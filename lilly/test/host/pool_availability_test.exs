defmodule Lilly.Host.PoolAvailabilityTest do
  use ExUnit.Case, async: false
  alias Lilly.Host.{Lock, Pool}
  @moduletag :tmp_dir
  @metadata [:event, :stage, :pool_id]

  test "a withheld pool is reported once per stage change, never per collection",
       %{tmp_dir: dir} do
    File.chmod!(dir, 0o700)
    id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    identity = %{backend: :zfs, zpool_guid: "1", dataset_guid: "2", dataset: "tank/lilly"}
    pool = %Pool{id: id, path: dir, filesystem_id: "zfs:1:2", storage: identity}
    on_exit(fn -> :persistent_term.erase({Pool, :availability, id}) end)
    {:ok, owner} = Lock.acquire(Path.join(dir, ".lilly-storage"))

    log =
      try do
        ExUnit.CaptureLog.capture_log([metadata: @metadata], fn ->
          for _ <- 1..3 do
            assert %{busy: true} = Task.await(Task.async(fn -> Pool.report(pool) end))
          end
        end)
      after
        Lock.release(owner)
      end

    assert length(String.split(log, "pool.snapshot_withheld")) == 2
    assert log =~ "stage=storage_busy"
    refute log =~ "pool.snapshot_recovered"
  end
end
