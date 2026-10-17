defmodule Lilly.VM.WorkloadBundleTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog

  test "refusal logs placement and a closed reason without paths or image data" do
    placement = Lilly.UUID.generate()
    image_id = "sha256:" <> String.duplicate("a", 64)
    {:ok, guest} = Lilly.Network.Guest.new(placement, :customer, 2)

    spec = %Lilly.VM.Spec{
      id: placement,
      image_id: image_id,
      pool_id: Lilly.UUID.generate(),
      network: guest,
      vcpu: 1,
      memory_bytes: 1_073_741_824,
      disk_bytes: 4_294_967_296
    }

    stat = %File.Stat{size: 1}

    image = %Lilly.Host.Image{
      id: image_id,
      path: "/secret/image",
      manifest: %{
        architecture: :x86_64,
        boot_kind: :kernel,
        boot_args: "console=ttyS0",
        manifest: %{"kernel" => %{}, "initrd" => %{}}
      },
      files: %{"kernel" => {"/secret/kernel", stat}, "initrd" => {"/secret/initrd", stat}}
    }

    log =
      capture_log([metadata: [:event, :placement_id, :reason]], fn ->
        assert {:error, :workload_bundle_materialization_failed} =
                 Lilly.VM.WorkloadBundle.materialize("/missing/secret/placement", image, spec)
      end)

    assert log =~ "event=lilly.workload_bundle_refused"
    assert log =~ "placement_id=#{placement}"
    assert log =~ "reason=workload_bundle_materialization_failed"
    refute log =~ "/secret/"
    refute log =~ image_id
  end
end
