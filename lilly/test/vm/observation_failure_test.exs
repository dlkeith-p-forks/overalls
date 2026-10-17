defmodule Lilly.VM.ObservationFailureTest do
  use ExUnit.Case, async: false

  alias Lilly.VM.Observation

  defp fixture do
    placement = Lilly.UUID.generate()
    {:ok, network} = Lilly.Network.Config.new(Lilly.UUID.generate(), "eth0", [], "/tmp/net")
    {:ok, guest} = Lilly.Network.Guest.new(placement, :customer, 2)

    config = %Lilly.VM.Config{
      state_dir: "/tmp/vms",
      network: network,
      firecracker: "/tools/firecracker",
      jailer: "/tools/jailer",
      unshare: "/tools/unshare",
      launch_guard: "/tools/guard",
      boot_log_writer: "/tools/boot-log"
    }

    spec = %Lilly.VM.Spec{
      id: placement,
      image_id: "fixture",
      pool_id: Lilly.UUID.generate(),
      network: guest,
      vcpu: 2,
      memory_bytes: 1_073_741_824,
      disk_bytes: 4_294_967_296
    }

    pool = %Lilly.Host.Pool{id: spec.pool_id, path: "/tmp/pool", filesystem_id: "fixture"}
    {config, pool, spec}
  end

  # @cc [owner:ghuntley,label:verification;observability] observation-failure-named-once
  # Without a running unit the first failing check MUST be unit_not_running;
  # repeated failures of the same check MUST emit vm.observation_failed once,
  # with only the placement id and the check atom.
  test "an absent unit names its check and is reported once per consecutive failure" do
    {config, pool, spec} = fixture()
    assert {:error, :unit_not_running} = Observation.check(config, pool, spec)

    output =
      ExUnit.CaptureLog.capture_log(
        [level: :info, formatter: {LoggerJSON.Formatters.Basic, metadata: :all}],
        fn ->
          assert :error = Observation.vmm(config, pool, spec)
          assert :error = Observation.vmm(config, pool, spec)
          refute Observation.running?(config, pool, spec)
        end
      )

    events =
      output
      |> String.split("\n", trim: true)
      |> Enum.map(&JSON.decode!/1)
      |> Enum.filter(&(get_in(&1, ["metadata", "event"]) == "vm.observation_failed"))

    assert [event] = events
    assert event["metadata"]["check"] == "unit_not_running"
    assert event["metadata"]["placement_id"] == spec.id
    refute output =~ "/tmp/pool"
  end
end
