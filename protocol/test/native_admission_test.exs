defmodule OverallsProtocol.NativeAdmissionTest do
  use ExUnit.Case, async: true
  import Hegel, except: [draw: 2]
  import OverallsProtocol.TestProperties, only: [draw: 2]
  alias OverallsProtocol.{GuestAgents, ImageManifest, NativeAdmission, WorkloadBundle}

  # @cc [owner:ghuntley,label:verification;security] native-admission-refuses-substituted-identity
  # Codec-valid images with any changed content-bound field and portable bundles
  # with substituted identity or provenance MUST remain unadmitted. These pure
  # tests establish policy only, not kernel or production execution evidence.
  property "codec-valid root and firmware substitutions cannot inherit reviewed capabilities",
    database: :disabled,
    print_blob: false,
    test_cases: 64,
    seed: 20_261_017 do
    digest = draw("root_digest", Hegel.Gen.binary(32, 32))
    sha256 = Base.encode16(digest, case: :lower)

    for os <- [:freebsd, :illumos],
        path <- [["root", "sha256"], ["boot", "firmware", "sha256"]] do
      manifest = NativeAdmission.reviewed_manifest(os)
      changed = put_in(manifest, path, sha256)
      assert {:ok, image} = ImageManifest.validate(changed)

      if changed != manifest do
        refute NativeAdmission.admitted?(image)
        refute Enum.any?(Map.values(GuestAgents.capabilities(image.guest_agents, image)))
      end
    end
  end

  for {os, agents, other_os, other_agents} <- [
        {:freebsd, :freebsd_v1, :illumos, :illumos_v1},
        {:illumos, :illumos_v1, :freebsd, :freebsd_v1}
      ] do
    @os os
    @agents agents
    @other_os other_os
    @other_agents other_agents

    test "only exact reviewed #{@os} image context activates supported capabilities" do
      assert {:ok, image} = ImageManifest.validate(NativeAdmission.reviewed_manifest(@os))
      assert NativeAdmission.admitted?(image)

      assert %{editor: false, inception: false} =
               capabilities = GuestAgents.capabilities(@agents, image)

      assert Enum.all?(Map.values(Map.drop(capabilities, [:editor, :inception])))
      refute Enum.any?(Map.values(GuestAgents.capabilities(@agents)))
      refute Enum.any?(Map.values(GuestAgents.capabilities(@other_agents, image)))

      for {path, value} <- [
            {["root", "bytes"], image.manifest["root"]["bytes"] + 1},
            {["boot", "firmware", "bytes"], image.manifest["boot"]["firmware"]["bytes"] + 1},
            {["kernel", "bytes"], image.kernel.bytes + 1},
            {["kernel", "sha256"], String.duplicate("a", 64)},
            {["kernel", "source_revision"], String.duplicate("b", 40)},
            {["kernel", "patch_hash"], String.duplicate("c", 64)},
            {["kernel", "configuration_hash"], String.duplicate("d", 64)},
            {["kernel", "compiler"], "different-compiler"},
            {["minimum_memory_bytes"], image.minimum_memory_bytes + 1_073_741_824},
            {["minimum_disk_bytes"], image.minimum_disk_bytes + 1_073_741_824},
            {["workspace_source_version"], nil}
          ] do
        assert {:ok, changed} = ImageManifest.validate(put_in(image.manifest, path, value))
        refute NativeAdmission.admitted?(changed)
        refute Enum.any?(Map.values(GuestAgents.capabilities(@agents, changed)))
      end

      assert {:ok, foreign} =
               ImageManifest.validate(
                 image.manifest
                 |> Map.put("os", Atom.to_string(@other_os))
                 |> Map.put("guest_agents", GuestAgents.wire(@other_agents))
               )

      refute NativeAdmission.admitted?(foreign)
      refute Enum.any?(Map.values(GuestAgents.capabilities(@other_agents, foreign)))
    end

    test "portable #{@os} context binds the reviewed ID and all retained boot descriptors" do
      assert {:ok, image} = ImageManifest.validate(NativeAdmission.reviewed_manifest(@os))

      bundle = %{
        image_id: image.id,
        architecture: :x86_64,
        boot_kind: :firmware,
        os: @os,
        guest_agents: @agents,
        pci: true,
        firmware_bytes: image.manifest["boot"]["firmware"]["bytes"],
        kernel: image.kernel
      }

      assert {:ok, ^bundle} = bundle |> WorkloadBundle.encode() |> WorkloadBundle.validate()
      assert NativeAdmission.admitted?(bundle)
      assert GuestAgents.capabilities(@agents, bundle).terminal

      for changed <- [
            %{bundle | image_id: "sha256:" <> String.duplicate("0", 64)},
            %{bundle | firmware_bytes: bundle.firmware_bytes + 1},
            %{bundle | os: @other_os, guest_agents: @other_agents},
            put_in(bundle.kernel.bytes, image.kernel.bytes + 1),
            put_in(bundle.kernel.sha256, String.duplicate("e", 64)),
            put_in(bundle.kernel.source_revision, String.duplicate("f", 40)),
            put_in(bundle.kernel.patch_hash, String.duplicate("e", 64)),
            put_in(bundle.kernel.configuration_hash, String.duplicate("e", 64)),
            put_in(bundle.kernel.compiler, "different-compiler")
          ] do
        assert {:ok, ^changed} = changed |> WorkloadBundle.encode() |> WorkloadBundle.validate()
        refute NativeAdmission.admitted?(changed)
        refute GuestAgents.capabilities(changed.guest_agents, changed).trust
      end

      for invalid <- [
            nil,
            image.id,
            %{guest_agents: @agents},
            Map.put(bundle, :unreviewed_field, true),
            %{image | id: bundle.image_id <> "0"}
          ] do
        refute NativeAdmission.admitted?(invalid)
        refute GuestAgents.capabilities(@agents, invalid).readiness
      end
    end
  end

  test "the default reviewed manifest remains the FreeBSD identity" do
    assert NativeAdmission.reviewed_manifest() == NativeAdmission.reviewed_manifest(:freebsd)
  end

  test "cold admission does not grant memory continuation to unqualified native images" do
    assert NativeAdmission.checkpoint_admitted?(%{guest_agents: :linux, boot_kind: :kernel})

    for os <- [:freebsd, :illumos] do
      assert {:ok, image} = ImageManifest.validate(NativeAdmission.reviewed_manifest(os))
      assert NativeAdmission.admitted?(image)
      refute NativeAdmission.checkpoint_admitted?(image)
    end

    for identity <- [
          nil,
          %{},
          %{guest_agents: :none, boot_kind: :kernel},
          %{guest_agents: :windows_v1, boot_kind: :firmware},
          %{guest_agents: :linux, boot_kind: :firmware}
        ] do
      refute NativeAdmission.checkpoint_admitted?(identity)
    end
  end
end
