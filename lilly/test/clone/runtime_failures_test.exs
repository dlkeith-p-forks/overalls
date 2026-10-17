defmodule Lilly.Clone.RuntimeFailuresTest do
  # capture_log observes global Logger traffic and the catalogued message is
  # fixed for every emitting module, so counting assertions need exclusive
  # execution.
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  alias Lilly.Clone.{Reason, Runtime}

  @clone "00000000-0000-4000-8000-000000000001"

  defp command(id, kind), do: %{"id" => id, "clone_id" => @clone, "kind" => kind}

  defp state(offered, failures \\ %{}),
    do: %{offered: MapSet.new(offered), failures: failures}

  # @cc [owner:ghuntley,label:verification;observability] clone-effect-failure-diagnostics-tested
  # The pure attempt reporter MUST emit once per effect and reason change and
  # again after an intervening success, never once per retry.
  test "an unconfirmed effect is reported once per reason change and again after success" do
    prune = command("effect-1", "prune")

    output =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :reason, :utility, :stage]], fn ->
        first =
          Runtime.report_attempts(state(["effect-1"]), [
            {prune, :snapshot_unconfirmed, :snapshot_index_unconfirmed}
          ])

        assert first.failures == %{
                 "effect-1" => {:snapshot_unconfirmed, :snapshot_index_unconfirmed}
               }

        repeated =
          Runtime.report_attempts(first, [
            {prune, :snapshot_unconfirmed, :snapshot_index_unconfirmed}
          ])

        assert repeated.failures == first.failures

        # The same wire reason from a different internal check is a change.
        staged =
          Runtime.report_attempts(repeated, [
            {prune, :snapshot_unconfirmed, :snapshot_state_unconfirmed}
          ])

        assert staged.failures == %{
                 "effect-1" => {:snapshot_unconfirmed, :snapshot_state_unconfirmed}
               }

        changed =
          Runtime.report_attempts(staged, [{prune, :mount_unconfirmed, :clone_mount_unconfirmed}])

        assert changed.failures == %{"effect-1" => {:mount_unconfirmed, :clone_mount_unconfirmed}}
        recovered = Runtime.report_attempts(changed, [{prune, :ok}])
        assert recovered.failures == %{}

        again =
          Runtime.report_attempts(recovered, [
            {prune, :mount_unconfirmed, :clone_mount_unconfirmed}
          ])

        assert again.failures == %{"effect-1" => {:mount_unconfirmed, :clone_mount_unconfirmed}}
      end)

    assert length(Regex.scan(~r/Clone effect unconfirmed/, output)) == 4
    assert output =~ "snapshot_unconfirmed"
    assert output =~ "stage=snapshot_index_unconfirmed"
    assert output =~ "stage=snapshot_state_unconfirmed"
    assert output =~ "mount_unconfirmed"
    assert output =~ "prune"
  end

  test "contended reasons log at the default level and forgotten offers drop their record" do
    copy = command("effect-2", "copy")

    output =
      ExUnit.CaptureLog.capture_log([metadata: [:event, :reason]], fn ->
        reported =
          Runtime.report_attempts(state(["effect-2"]), [{copy, :storage_busy, :storage_busy}])

        assert reported.failures == %{"effect-2" => {:storage_busy, :storage_busy}}
        forgotten = Runtime.report_attempts(%{reported | offered: MapSet.new()}, [])
        assert forgotten.failures == %{}
      end)

    assert length(Regex.scan(~r/Clone effect deferred by host contention/, output)) == 1
    refute output =~ "Clone effect unconfirmed"
  end

  property "classification is total and every reason is in the closed wire set" do
    reasons = Enum.map(OverallsProtocol.CloneControl.unconfirmed_reasons(), &String.to_atom/1)

    check all(internal <- one_of([atom(:alphanumeric), binary(), integer(), constant(nil)])) do
      assert Reason.classify(internal) in reasons
    end

    for internal <- [:storage_busy, :source_authority_unconfirmed, :clone_copy_unconfirmed] do
      assert Reason.classify(internal) in reasons
    end

    # The claim-shape refusal that stalled production pruning names the source,
    # not the snapshot, and the stage never becomes a peer or native value.
    assert Reason.classify(:zfs_snapshot_source_unconfirmed) == :source_unconfirmed
    assert Reason.classify(:zfs_snapshot_claim_unconfirmed) == :source_unconfirmed
    assert Reason.classify(:zfs_ownership_unconfirmed) == :source_authority_unconfirmed
    assert Reason.stage(:zfs_snapshot_source_unconfirmed) == :zfs_snapshot_source_unconfirmed
    assert Reason.stage({:exit, "native"}) == :unknown
    assert Reason.stage(nil) == :unknown
  end
end
