defmodule Lilly.Host.ZFSLoggingTest do
  use ExUnit.Case, async: false
  alias Lilly.Host.ZFS
  @moduletag :tmp_dir
  @placement "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
  @metadata [:event, :placement_id, :stage, :reason]

  # @cc [owner:ghuntley,label:verification;security] observation-diagnostic-refusal-boundary
  # Missing-path refusal MUST remain identical with diagnostics enabled. Only a
  # validated placement and fixed classification may be logged; ordinary capacity
  # observation and invalid diagnostic identities MUST not emit the readiness event.
  # This unprivileged identity-refusal check MUST NOT establish native ZFS acceptance.
  test "readiness observation reports identity refusal without raw paths or changed results",
       context do
    missing = Path.join(context.tmp_dir, "unlogged-native-path")

    identity = %{
      path: missing,
      filesystem_id: "zfs:1:2",
      storage: %{backend: :zfs, zpool_guid: "1", dataset_guid: "2", dataset: "tank/lilly"},
      extents: []
    }

    ordinary =
      ExUnit.CaptureLog.capture_log([metadata: @metadata], fn ->
        assert {:error, :incoherent_zfs_observation} = ZFS.observe(identity)
      end)

    refute ordinary =~ "vm.dataset_observation_failed"
    refute ordinary =~ "vm.dataset_identity_probe_failed"

    diagnostic =
      ExUnit.CaptureLog.capture_log([metadata: @metadata], fn ->
        assert {:error, :incoherent_zfs_observation} =
                 ZFS.observe_for_readiness(identity, %{}, @placement)
      end)

    assert diagnostic =~ "vm.dataset_observation_failed"
    assert diagnostic =~ "vm.dataset_identity_probe_failed"
    assert diagnostic =~ "placement_id=#{@placement}"
    assert diagnostic =~ "stage=identity_before"
    assert diagnostic =~ "reason=unconfirmed"
    assert diagnostic =~ "reason=canonical_path"
    refute diagnostic =~ missing
    refute diagnostic =~ "tank/lilly"

    invalid =
      ExUnit.CaptureLog.capture_log([metadata: @metadata], fn ->
        assert {:error, :incoherent_zfs_observation} =
                 ZFS.observe_for_readiness(identity, %{}, "unvalidated-identity")
      end)

    refute invalid =~ "vm.dataset_observation_failed"
    refute invalid =~ "vm.dataset_identity_probe_failed"
    refute invalid =~ "unvalidated-identity"
  end
end
