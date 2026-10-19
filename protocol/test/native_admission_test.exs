defmodule OverallsProtocol.NativeAdmissionTest do
  use ExUnit.Case, async: true
  import Hegel, except: [draw: 2]
  import OverallsProtocol.TestProperties, only: [draw: 2]
  alias OverallsProtocol.{GuestAgents, ImageManifest, NativeAdmission, WorkloadBundle}

  test "the reviewed Android guest profile is admitted as a Linux image" do
    identity = %{guest_agents: :linux_android_v1}
    assert NativeAdmission.admitted?(identity)
    refute NativeAdmission.checkpoint_admitted?(Map.put(identity, :boot_kind, :kernel))
  end

  # @cc [owner:ghuntley,label:verification;security] native-admission-refuses-substituted-identity
  # Codec-valid images with any changed content-bound field and portable bundles
  # with substituted identity or provenance MUST remain unadmitted. These pure
  # tests establish policy only, not kernel or production execution evidence.
  property "codec-valid root and firmware substitutions cannot inherit reviewed capabilities",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
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

      assert GuestAgents.capabilities(@agents, image) == %{
               readiness: true,
               trust: true,
               terminal: true,
               workspace: true,
               flush: true,
               ssh: true,
               agents: true,
               editor: false,
               inception: false,
               android_sdk: false,
               adb: false,
               android_emulator: false,
               android_display: false
             }

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

      bundle =
        if Map.get(image, :git_identity_version) == 1,
          do: Map.put(bundle, :git_identity_version, 1),
          else: bundle

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

  test "selected defaults belong to explicit immutable history and every retained identity remains admitted" do
    for os <- [:freebsd, :illumos] do
      history = NativeAdmission.reviewed_manifests(os)
      assert NativeAdmission.reviewed_manifest(os) in history
      assert history != []

      ids =
        Enum.map(history, fn manifest ->
          assert {:ok, image} = ImageManifest.validate(manifest)
          assert NativeAdmission.admitted?(image)
          refute NativeAdmission.checkpoint_admitted?(image)

          bundle = %{
            image_id: image.id,
            architecture: image.architecture,
            boot_kind: image.boot_kind,
            os: image.os,
            guest_agents: image.guest_agents,
            pci: image.pci,
            firmware_bytes: manifest["boot"]["firmware"]["bytes"],
            kernel: image.kernel
          }

          bundle =
            if Map.get(image, :git_identity_version) == 1,
              do: Map.put(bundle, :git_identity_version, 1),
              else: bundle

          assert {:ok, ^bundle} = bundle |> WorkloadBundle.encode() |> WorkloadBundle.validate()
          assert NativeAdmission.admitted?(bundle)
          refute NativeAdmission.checkpoint_admitted?(bundle)

          refute NativeAdmission.admitted?(%{
                   bundle
                   | image_id: "sha256:" <> String.duplicate("0", 64)
                 })

          image.id
        end)

      assert Enum.uniq(ids) == ids
    end
  end

  test "Git identity selection preserves immutable legacy admission without relabelling" do
    candidate = NativeAdmission.reviewed_manifest(:freebsd)
    assert {:ok, %{git_identity_version: 1} = image} = ImageManifest.validate(candidate)
    assert NativeAdmission.admitted?(image)
    refute NativeAdmission.checkpoint_admitted?(image)
    assert candidate in NativeAdmission.reviewed_manifests(:freebsd)
    refute NativeAdmission.admitted?(Map.delete(image, :git_identity_version))

    legacy_manifest =
      Path.expand("../priv/native/freebsd-14.3.json", __DIR__)
      |> File.read!()
      |> JSON.decode!()

    assert {:ok, legacy} = ImageManifest.validate(legacy_manifest)
    assert legacy.id != image.id
    refute Map.has_key?(legacy, :git_identity_version)
    assert NativeAdmission.admitted?(legacy)
    refute NativeAdmission.admitted?(Map.put(legacy, :git_identity_version, 1))
    refute NativeAdmission.checkpoint_admitted?(legacy)

    for current <- [legacy, image] do
      bundle = %{
        image_id: current.id,
        architecture: current.architecture,
        boot_kind: current.boot_kind,
        os: current.os,
        guest_agents: current.guest_agents,
        pci: current.pci,
        firmware_bytes: current.manifest["boot"]["firmware"]["bytes"],
        kernel: current.kernel
      }

      if current == legacy do
        assert NativeAdmission.admitted?(bundle)
        refute NativeAdmission.admitted?(Map.put(bundle, :git_identity_version, 1))
      else
        refute NativeAdmission.admitted?(bundle)
        assert NativeAdmission.admitted?(Map.put(bundle, :git_identity_version, 1))
      end
    end

    assert {:ok, omnios} = ImageManifest.validate(NativeAdmission.reviewed_manifest(:illumos))
    refute Map.has_key?(omnios, :git_identity_version)
    assert NativeAdmission.admitted?(omnios)
  end

  test "the default reviewed manifest remains the FreeBSD identity" do
    assert NativeAdmission.reviewed_manifest() == NativeAdmission.reviewed_manifest(:freebsd)
  end

  # @cc [owner:ghuntley,label:verification;recovery] checkpoint-exact-image-qualification
  # Changing any artifact digest MUST lose qualification while cold admission
  # remains independent; both validated manifest and portable bundle bind one ID.
  property "checkpoint qualification follows exact content identity", database: :disabled do
    digest = draw("qualified_digest", Hegel.Gen.binary(32, 32))
    digest = Base.encode16(digest, case: :lower)
    artifact = %{"bytes" => 1024, "sha256" => digest}

    manifest = %{
      "version" => 4,
      "workspace_source_version" => nil,
      "architecture" => "x86_64",
      "boot_args" => "console=ttyS0",
      "minimum_memory_bytes" => 536_870_912,
      "minimum_disk_bytes" => 2_147_483_648,
      "kernel" => artifact,
      "initrd" => artifact,
      "rootfs" => artifact
    }

    assert {:ok, image} = ImageManifest.validate(manifest)
    assert NativeAdmission.admitted?(image)
    refute NativeAdmission.checkpoint_admitted?(image)
    assert NativeAdmission.checkpoint_admitted?(image, [image.id])

    assert {:ok, bundle} =
             WorkloadBundle.validate(%{
               "version" => 1,
               "image_id" => image.id,
               "architecture" => "x86_64",
               "boot_args" => image.boot_args,
               "kernel_bytes" => 1024,
               "initrd_bytes" => 1024
             })

    assert NativeAdmission.checkpoint_admitted?(bundle, [image.id])

    for artifact_name <- ["kernel", "initrd", "rootfs"] do
      changed =
        put_in(
          manifest,
          [artifact_name, "sha256"],
          if(digest == String.duplicate("f", 64),
            do: String.duplicate("e", 64),
            else: String.duplicate("f", 64)
          )
        )

      assert {:ok, changed_image} = ImageManifest.validate(changed)
      assert NativeAdmission.admitted?(changed_image)
      refute NativeAdmission.checkpoint_admitted?(changed_image, [image.id])

      refute NativeAdmission.checkpoint_admitted?(%{bundle | image_id: changed_image.id}, [
               image.id
             ])
    end

    for invalid <- [
          nil,
          %{},
          %{guest_agents: :linux, boot_kind: :kernel},
          %{bundle | image_id: "invalid"},
          %{bundle | guest_agents: :windows_v1},
          %{bundle | boot_kind: :firmware}
        ] do
      refute NativeAdmission.checkpoint_admitted?(invalid, [image.id])
    end
  end

  property "qualification supersets preserve exact per-image admission", database: :disabled do
    digest = draw("qualified image", Hegel.Gen.binary(32, 32)) |> Base.encode16(case: :lower)
    image_id = "sha256:" <> digest

    other_id =
      "sha256:" <>
        if(digest == String.duplicate("f", 64),
          do: String.duplicate("e", 64),
          else: String.duplicate("f", 64)
        )

    assert NativeAdmission.checkpoint_qualified?(image_id, [image_id])
    assert NativeAdmission.checkpoint_qualified?(image_id, [other_id, image_id])
    refute NativeAdmission.checkpoint_qualified?(image_id, [other_id])
    refute NativeAdmission.checkpoint_qualified?(image_id, nil)
    refute NativeAdmission.checkpoint_qualified?(image_id, [image_id, image_id])
  end

  test "cold admission does not grant memory continuation to unqualified native images" do
    refute NativeAdmission.checkpoint_admitted?(%{guest_agents: :linux, boot_kind: :kernel})

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
