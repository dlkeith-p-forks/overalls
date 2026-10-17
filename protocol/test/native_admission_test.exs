defmodule OverallsProtocol.NativeAdmissionTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.{GuestAgents, ImageManifest, NativeAdmission, WorkloadBundle}

  # @cc [owner:ghuntley,label:verification;security] native-admission-refuses-substituted-identity
  # Codec-valid images with any changed content-bound field and portable bundles
  # with substituted identity or provenance MUST remain unadmitted. These pure
  # tests establish policy only, not kernel or production execution evidence.
  property "a codec-valid root substitution cannot inherit reviewed capabilities",
    database: :disabled,
    test_cases: 64,
    seed: 20_261_017 do
    digest = draw("root_digest", Hegel.Gen.binary(32, 32))
    sha256 = Base.encode16(digest, case: :lower)
    manifest = NativeAdmission.reviewed_manifest()
    changed = put_in(manifest, ["root", "sha256"], sha256)
    assert {:ok, image} = ImageManifest.validate(changed)

    if changed != manifest do
      refute NativeAdmission.admitted?(image)
      refute Enum.any?(Map.values(GuestAgents.capabilities(:freebsd_v1, image)))
    end
  end

  test "only exact reviewed native image context activates supported capabilities" do
    assert {:ok, image} = ImageManifest.validate(NativeAdmission.reviewed_manifest())
    assert NativeAdmission.admitted?(image)

    assert %{editor: false, inception: false} =
             capabilities =
             GuestAgents.capabilities(:freebsd_v1, image)

    assert Enum.all?(Map.values(Map.drop(capabilities, [:editor, :inception])))
    refute Enum.any?(Map.values(GuestAgents.capabilities(:freebsd_v1)))
    refute Enum.any?(Map.values(GuestAgents.capabilities(:illumos_v1, image)))

    for {path, value} <- [
          {["boot", "firmware", "sha256"], String.duplicate("a", 64)},
          {["kernel", "source_revision"], String.duplicate("b", 40)},
          {["kernel", "patch_hash"], String.duplicate("c", 64)},
          {["kernel", "configuration_hash"], String.duplicate("d", 64)},
          {["kernel", "compiler"], "different-compiler"},
          {["minimum_memory_bytes"], 2_147_483_648},
          {["workspace_source_version"], nil}
        ] do
      assert {:ok, changed} = ImageManifest.validate(put_in(image.manifest, path, value))
      refute NativeAdmission.admitted?(changed)
      refute Enum.any?(Map.values(GuestAgents.capabilities(:freebsd_v1, changed)))
    end

    assert {:ok, illumos} =
             ImageManifest.validate(
               image.manifest
               |> Map.put("os", "illumos")
               |> Map.put("guest_agents", "illumos-v1")
             )

    refute NativeAdmission.admitted?(illumos)
  end

  test "portable context binds the reviewed ID and all retained boot descriptors" do
    assert {:ok, image} = ImageManifest.validate(NativeAdmission.reviewed_manifest())

    bundle = %{
      image_id: image.id,
      architecture: :x86_64,
      boot_kind: :firmware,
      os: :freebsd,
      guest_agents: :freebsd_v1,
      pci: true,
      firmware_bytes: image.manifest["boot"]["firmware"]["bytes"],
      kernel: image.kernel
    }

    assert {:ok, ^bundle} = bundle |> WorkloadBundle.encode() |> WorkloadBundle.validate()
    assert NativeAdmission.admitted?(bundle)
    assert GuestAgents.capabilities(:freebsd_v1, bundle).terminal

    for changed <- [
          %{bundle | image_id: "sha256:" <> String.duplicate("0", 64)},
          %{bundle | firmware_bytes: bundle.firmware_bytes + 1},
          put_in(bundle.kernel.sha256, String.duplicate("e", 64)),
          put_in(bundle.kernel.compiler, "different-compiler")
        ] do
      assert {:ok, ^changed} = changed |> WorkloadBundle.encode() |> WorkloadBundle.validate()
      refute NativeAdmission.admitted?(changed)
      refute GuestAgents.capabilities(:freebsd_v1, changed).trust
    end

    for invalid <- [
          nil,
          image.id,
          %{guest_agents: :freebsd_v1},
          %{image | id: bundle.image_id <> "0"}
        ] do
      refute NativeAdmission.admitted?(invalid)
      refute GuestAgents.capabilities(:freebsd_v1, invalid).readiness
    end
  end
end
