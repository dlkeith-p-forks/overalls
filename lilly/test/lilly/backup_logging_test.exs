defmodule Lilly.BackupLoggingTest do
  use ExUnit.Case, async: false
  import ExUnit.CaptureLog

  @metadata [:event, :operation, :placement_id, :pool_id, :run_id, :reason]
  @id "00000000-0000-4000-8000-000000000001"

  test "backup result correlation includes only validated identities" do
    output =
      capture_log([metadata: @metadata], fn ->
        assert Lilly.Backup.outcome(
                 "capture",
                 {:ok, %{id: @id, pool_id: @id, run_id: @id, paths: ["private-path"]}}
               ) == 0

        assert Lilly.Backup.outcome("capture", {:ok, %{id: "private-id", run_id: "private-run"}}) ==
                 0
      end)

    assert output =~ "operation=capture"
    assert output =~ "run_id=#{@id}"
    assert output =~ "placement_id=#{@id}"
    refute output =~ "private-path"
    refute output =~ "private-id"
    refute output =~ "private-run"
  end

  test "backup failures retain a closed stage reason without payloads or raw operation" do
    output =
      capture_log([metadata: @metadata], fn ->
        assert Lilly.Backup.outcome("capture", {:error, :backup_mount_unconfirmed}) == 1
        assert Lilly.Backup.outcome("private-operation", {:error, %{token: "private-token"}}) == 1
      end)

    assert output =~ "reason=backup_mount_unconfirmed"
    assert output =~ "reason=backup_unconfirmed"
    assert output =~ "operation=unknown"
    refute output =~ "private-operation"
    refute output =~ "private-token"
  end
end
