defmodule OverallsProtocol.ImageManifestTest do
  use ExUnit.Case, async: true
  import Hegel, except: [draw: 2]
  import OverallsProtocol.TestProperties, only: [draw: 2]
  import Hegel.Gen
  alias OverallsProtocol.ImageManifest

  defp manifest do
    artifact = %{"bytes" => 1024, "sha256" => String.duplicate("a", 64)}

    %{
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
  end

  defp firmware_manifest do
    %{
      "version" => 5,
      "architecture" => "x86_64",
      "boot" => %{
        "kind" => "firmware",
        "pci" => true,
        "firmware" => %{"bytes" => 4_194_304, "sha256" => String.duplicate("b", 64)}
      },
      "root" => %{
        "format" => "raw-gpt",
        "bytes" => 34_359_738_368,
        "sha256" => String.duplicate("c", 64)
      },
      "guest_agents" => "none",
      "minimum_memory_bytes" => 2_147_483_648,
      "minimum_disk_bytes" => 34_359_738_368,
      "workspace_source_version" => nil
    }
  end

  defp illumos_manifest do
    kernel = %{
      "bytes" => 1_048_576,
      "sha256" => String.duplicate("d", 64),
      "source_revision" => String.duplicate("1", 40),
      "patch_hash" => String.duplicate("2", 64),
      "configuration_hash" => String.duplicate("3", 64),
      "compiler" => "clang-19.1.7"
    }

    %{
      "version" => 6,
      "os" => "illumos",
      "architecture" => "x86_64",
      "boot" => %{
        "kind" => "firmware",
        "pci" => true,
        "firmware" => %{"bytes" => 4_194_304, "sha256" => String.duplicate("e", 64)}
      },
      "root" => %{
        "format" => "raw-gpt",
        "bytes" => 8_589_934_592,
        "sha256" => String.duplicate("f", 64)
      },
      "kernel" => kernel,
      "guest_agents" => "illumos-v1",
      "minimum_memory_bytes" => 536_870_912,
      "minimum_disk_bytes" => 8_589_934_592,
      "workspace_source_version" => nil
    }
  end

  property "Git identity capability is explicit, identity-bound and closed across image kinds",
    database: :disabled,
    print_blob: false,
    test_cases: 50,
    seed: 814_029_311 do
    kind = draw("image kind", member_of([:linux, :windows, :none, :freebsd, :illumos]))

    base =
      case kind do
        :linux -> manifest()
        :windows -> Map.put(firmware_manifest(), "guest_agents", "windows-v1")
        :none -> firmware_manifest()
        :freebsd -> OverallsProtocol.NativeAdmission.reviewed_manifest()
        :illumos -> illumos_manifest()
      end

    assert {:ok, original} = ImageManifest.validate(base)
    refute ImageManifest.git_identity?(base)
    capable = Map.put(base, "git_identity_version", 1)

    if kind == :none do
      assert {:error, :invalid_image_manifest} = ImageManifest.validate(capable)
    else
      assert {:ok, image} = ImageManifest.validate(capable)
      refute image.id == original.id
      assert image.git_identity_version == 1
      assert ImageManifest.git_identity?(capable)
      assert ImageManifest.encode(image) == capable

      assert {:ok, ^image} =
               capable |> JSON.encode!() |> JSON.decode!() |> ImageManifest.validate()

      assert {:ok, ^original} =
               capable |> Map.delete("git_identity_version") |> ImageManifest.validate()

      assert {:error, :invalid_image_manifest} =
               ImageManifest.validate(Map.put(capable, "extra", true))

      if kind in [:freebsd, :illumos],
        do: refute(OverallsProtocol.NativeAdmission.admitted?(image))
    end

    for value <- [nil, 0, 2, "1", true] do
      malformed = Map.put(base, "git_identity_version", value)
      assert {:error, :invalid_image_manifest} = ImageManifest.validate(malformed)
      refute ImageManifest.git_identity?(malformed)
    end
  end

  property "identity survives serialization and changes with artifact bytes or boot requirements",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 565_971_739 do
    bytes = draw("bytes", integer(1..536_870_912))
    memory = draw("memory", integer(536_870_912..274_877_906_943))

    value =
      manifest()
      |> put_in(["kernel", "bytes"], bytes)
      |> Map.put("minimum_memory_bytes", memory)

    assert {:ok, image} = ImageManifest.validate(value)
    assert {:ok, ^image} = value |> JSON.encode!() |> JSON.decode!() |> ImageManifest.validate()

    assert {:ok, changed} =
             ImageManifest.validate(%{value | "minimum_memory_bytes" => memory + 1})

    refute image.id == changed.id
    assert ImageManifest.id?(image.id)
  end

  test "malformed manifests, unsupported architecture, unsafe arguments and insufficient disk fail" do
    base = manifest()

    for value <- [
          nil,
          %{},
          Map.put(base, "version", 1),
          Map.put(base, "version", 2),
          Map.put(base, "version", 3),
          # A kernel manifest cannot be promoted to version 5 by changing the number.
          Map.put(base, "version", 5),
          Map.put(base, "version", 6),
          Map.delete(base, "workspace_source_version"),
          Map.put(base, "workspace_source_version", 1),
          Map.put(base, "workspace_source_version", 3),
          Map.put(base, "workspace_source_version", "2"),
          Map.put(base, "architecture", "aarch64"),
          Map.put(base, "url", "https://example.test"),
          Map.put(base, "boot_args", "bad\0args"),
          Map.put(base, "minimum_disk_bytes", 1023),
          put_in(base, ["kernel", "sha256"], String.duplicate("A", 64)),
          put_in(base, ["kernel", "bytes"], 0),
          put_in(base, ["rootfs", "bytes"], 137_438_953_473)
        ] do
      assert {:error, :invalid_image_manifest} = ImageManifest.validate(value)
    end

    {:ok, image} = ImageManifest.validate(base)
    refute ImageManifest.ids?([image.id, image.id])
    refute ImageManifest.ids?(["missing"])
  end

  test "root image artifact accepts the 128 GiB boundary only when disk fits" do
    base = manifest()
    at_limit = put_in(base, ["rootfs", "bytes"], 137_438_953_472)
    assert {:error, :invalid_image_manifest} = ImageManifest.validate(at_limit)

    with_disk = Map.put(at_limit, "minimum_disk_bytes", 137_438_953_472)
    assert {:ok, _image} = ImageManifest.validate(with_disk)

    assert {:error, :invalid_image_manifest} =
             with_disk
             |> put_in(["rootfs", "bytes"], 137_438_953_473)
             |> Map.put("minimum_disk_bytes", 137_438_953_473)
             |> ImageManifest.validate()
  end

  test "kernel and initrd artifacts accept 8 GiB and reject one byte more" do
    for key <- ["kernel", "initrd"] do
      at_limit = put_in(manifest(), [key, "bytes"], 8_589_934_592)
      assert {:ok, _image} = ImageManifest.validate(at_limit)

      assert {:error, :invalid_image_manifest} =
               at_limit
               |> put_in([key, "bytes"], 8_589_934_593)
               |> ImageManifest.validate()
    end
  end

  test "image identity matches an independent compact JSON/SHA-256 test vector" do
    assert {:ok, %{id: "sha256:eeb47a8bb710690ac810aeea6a3b6a869272ed2816d5414a547ac3255b58607f"}} =
             ImageManifest.validate(manifest())
  end

  # @cc [owner:ghuntley,label:verification;protocol] kernel-agent-editor-composition
  # Explicit Linux/Android agents MUST compose with source and editor metadata,
  # bind identity, and round-trip; malformed, cross-OS or extra fields refuse.
  property "kernel agent declarations compose with editor and source metadata",
    database: :disabled,
    print_blob: false,
    test_cases: 100 do
    wire = draw("agents", member_of(["linux", "linux-android-v1"]))
    source = draw("source", member_of([nil, 2]))
    editor? = draw("editor", boolean())
    bytes = draw("root_bytes", integer(1..536_870_912))

    base =
      manifest()
      |> Map.put("workspace_source_version", source)
      |> put_in(["rootfs", "bytes"], bytes)

    base =
      if editor? do
        Map.put(base, "editor", %{
          "protocol" => 1,
          "commit" => String.duplicate("b", 40),
          "release" => String.duplicate("c", 64)
        })
      else
        base
      end

    assert {:ok, original} = ImageManifest.validate(base)
    value = Map.put(base, "guest_agents", wire)
    assert {:ok, image} = ImageManifest.validate(value)
    expected = if wire == "linux", do: :linux, else: :linux_android_v1
    assert ImageManifest.guest_agents(image) == expected
    assert ImageManifest.encode(image) == value
    assert image.id != original.id
    assert ImageManifest.editor(image) == ImageManifest.editor(original)

    capabilities = OverallsProtocol.GuestAgents.capabilities(image.guest_agents)
    assert capabilities.android_display == (wire == "linux-android-v1")
    assert capabilities.terminal

    for invalid <- [nil, "none", "windows-v1", "freebsd-v1", "linux-android-v2"] do
      assert {:error, :invalid_image_manifest} =
               ImageManifest.validate(Map.put(value, "guest_agents", invalid))
    end

    assert {:error, :invalid_image_manifest} =
             ImageManifest.validate(Map.put(value, "extra", true))

    assert {:error, :invalid_image_manifest} =
             ImageManifest.validate(Map.put(value, "editor", %{"protocol" => 1}))
  end

  test "kernel images expose the Linux boot kind, ext4 root and agent set" do
    assert {:ok, image} = ImageManifest.validate(manifest())

    assert %{
             boot_kind: :kernel,
             pci: false,
             root_format: :ext4,
             guest_agents: :linux,
             boot_args: "console=ttyS0"
           } = image

    assert ImageManifest.boot_kind(image) == :kernel
    assert ImageManifest.guest_agents(image) == :linux
    assert ImageManifest.boot_artifacts(image) == ["kernel", "initrd"]
    assert ImageManifest.root_artifact(image) == "rootfs.ext4"

    assert ImageManifest.artifact_files(image) == [
             {"kernel", manifest()["kernel"]},
             {"initrd", manifest()["initrd"]},
             {"rootfs.ext4", manifest()["rootfs"]}
           ]
  end

  property "source capability is explicit, survives encoding and changes immutable identity",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 1_478_275_591 do
    bytes = draw("bytes", integer(1..536_870_912))
    capability = draw("capability", member_of([nil, 2]))

    value =
      manifest()
      |> put_in(["rootfs", "bytes"], bytes)
      |> Map.put("workspace_source_version", capability)

    assert {:ok, image} = ImageManifest.validate(value)
    assert image.workspace_source_version == capability
    assert ImageManifest.workspace_source?(value) == (capability == 2)
    assert ImageManifest.encode(image) == value

    assert {:ok, changed} =
             value
             |> Map.put(
               "workspace_source_version",
               if(capability == 2) do
                 nil
               else
                 2
               end
             )
             |> ImageManifest.validate()

    refute image.id == changed.id
    assert {:ok, ^image} = image |> ImageManifest.encode() |> ImageManifest.validate()
  end

  test "source capability never comes from malformed or obsolete manifests" do
    for invalid <- [
          nil,
          %{},
          Map.put(manifest(), "version", 3),
          Map.put(manifest(), "workspace_source_version", "2"),
          Map.put(manifest(), "receiver_installed", true),
          firmware_manifest()
        ] do
      refute ImageManifest.workspace_source?(invalid)
    end

    assert {:error, :editor_unavailable} = ImageManifest.editor(firmware_manifest())
  end

  describe "version 5 firmware manifests" do
    test "identity matches an independent compact JSON/SHA-256 test vector" do
      # Computed outside Elixir from
      # ["lilly-image-v5","x86_64","firmware",true,"raw-gpt","none",2147483648,
      #  34359738368,null,[4194304,"b"*64],[34359738368,"c"*64]].
      assert {:ok,
              %{id: "sha256:596320d345588131b31a40d1dc723c14b02aa0f62ffd7d88dc003fc6880a315a"}} =
               ImageManifest.validate(firmware_manifest())
    end

    test "exposes the firmware boot kind, raw GPT root and no guest agents" do
      assert {:ok, image} = ImageManifest.validate(firmware_manifest())

      assert %{
               architecture: :x86_64,
               boot_kind: :firmware,
               pci: true,
               root_format: :raw_gpt,
               guest_agents: :none,
               minimum_memory_bytes: 2_147_483_648,
               minimum_disk_bytes: 34_359_738_368,
               workspace_source_version: nil
             } = image

      refute Map.has_key?(image, :boot_args)
      refute Map.has_key?(image, :editor)
      assert ImageManifest.boot_kind(image) == :firmware
      assert ImageManifest.guest_agents(image) == :none
      assert ImageManifest.boot_artifacts(image) == ["firmware"]
      assert ImageManifest.root_artifact(image) == "disk.raw"

      assert ImageManifest.artifact_files(image) == [
               {"firmware", %{"bytes" => 4_194_304, "sha256" => String.duplicate("b", 64)}},
               {"disk.raw", %{"bytes" => 34_359_738_368, "sha256" => String.duplicate("c", 64)}}
             ]

      assert ImageManifest.encode(image) == firmware_manifest()
      assert ImageManifest.id?(image.id)
    end

    test "only the closed eight-key firmware shape is admitted" do
      base = firmware_manifest()

      for value <- [
            Map.put(base, "name", "Windows Server 2025"),
            Map.put(base, "boot_args", "console=ttyS0"),
            Map.put(base, "kernel", %{"bytes" => 1, "sha256" => String.duplicate("a", 64)}),
            Map.put(base, "editor", %{}),
            Map.put(base, "editor_platform", %{"version" => 1, "os" => "windows"}),
            Map.put(base, "workspace_source_version", 2),
            Map.delete(base, "workspace_source_version"),
            Map.put(base, "guest_agents", "linux"),
            Map.put(base, "guest_agents", "windows-v2"),
            Map.put(base, "guest_agents", nil),
            Map.put(base, "architecture", "aarch64"),
            Map.put(base, "version", 4),
            put_in(base, ["boot", "kind"], "kernel"),
            put_in(base, ["boot", "pci"], false),
            put_in(base, ["boot", "initrd"], %{
              "bytes" => 1,
              "sha256" => String.duplicate("a", 64)
            }),
            update_in(base, ["boot"], &Map.delete(&1, "pci")),
            put_in(base, ["root", "format"], "ext4"),
            update_in(base, ["root"], &Map.delete(&1, "format")),
            put_in(base, ["root", "partition"], 3),
            put_in(base, ["boot", "firmware", "bytes"], 0),
            put_in(base, ["boot", "firmware", "bytes"], 67_108_865),
            put_in(base, ["boot", "firmware", "sha256"], String.duplicate("B", 64)),
            put_in(base, ["root", "sha256"], String.duplicate("c", 63)),
            Map.put(base, "minimum_disk_bytes", 34_359_738_367),
            Map.put(base, "minimum_memory_bytes", 536_870_911)
          ] do
        assert {:error, :invalid_image_manifest} = ImageManifest.validate(value),
               "expected refusal for #{inspect(value)}"
      end
    end

    test "the windows-v1 agent set is admitted, changes the identity and may carry source protocol 2" do
      # Vectors computed outside Elixir with "windows-v1" at identity index 5 and
      # the workspace source version at index 8 (nil, then 2).
      windows = Map.put(firmware_manifest(), "guest_agents", "windows-v1")

      assert {:ok,
              %{id: "sha256:ddc3debaffd14e1b4a859db42250ae8601955e7c2f0254ad9db1d501a7a9f56d"} =
                image} = ImageManifest.validate(windows)

      assert image.guest_agents == :windows_v1
      assert ImageManifest.guest_agents(image) == :windows_v1
      assert image.workspace_source_version == nil
      refute ImageManifest.workspace_source?(windows)
      {:ok, agentless} = ImageManifest.validate(firmware_manifest())
      refute image.id == agentless.id

      sourced = Map.put(windows, "workspace_source_version", 2)

      assert {:ok,
              %{id: "sha256:95de64c03d6aafa51d339e32b6e9e5f72fd7b21f7cd43fe98113d7918732bd8e"} =
                with_source} = ImageManifest.validate(sourced)

      assert with_source.workspace_source_version == 2
      assert ImageManifest.workspace_source?(sourced)
      assert {:error, :editor_unavailable} = ImageManifest.editor(sourced)

      # An agentless image cannot deliver a workspace source.
      assert {:error, :invalid_image_manifest} =
               ImageManifest.validate(Map.put(firmware_manifest(), "workspace_source_version", 2))

      for agents <- ["linux", "windows", "windows-v2", "", nil, 1] do
        assert {:error, :invalid_image_manifest} =
                 ImageManifest.validate(Map.put(windows, "guest_agents", agents))
      end
    end

    test "firmware accepts 64 MiB and the root accepts 128 GiB when the disk fits" do
      at_limit = put_in(firmware_manifest(), ["boot", "firmware", "bytes"], 67_108_864)
      assert {:ok, _} = ImageManifest.validate(at_limit)

      root_limit =
        firmware_manifest()
        |> put_in(["root", "bytes"], 137_438_953_472)
        |> Map.put("minimum_disk_bytes", 137_438_953_472)

      assert {:ok, _} = ImageManifest.validate(root_limit)

      assert {:error, :invalid_image_manifest} =
               root_limit
               |> put_in(["root", "bytes"], 137_438_953_473)
               |> Map.put("minimum_disk_bytes", 137_438_953_473)
               |> ImageManifest.validate()
    end

    property "identity survives serialization, changes with every bound input and never collides with v4",
      database: :disabled,
      print_blob: false,
      test_cases: 100,
      seed: 913_195_392 do
      firmware_bytes = draw("firmware_bytes", integer(1..67_108_864))
      root_bytes = draw("root_bytes", integer(1..137_438_953_472))
      memory = draw("memory", integer(536_870_912..274_877_906_943))

      digest =
        draw(
          "digest",
          OverallsProtocol.TestGenerators.string(Enum.concat(48..57, 97..102), length: 64)
        )

      value =
        firmware_manifest()
        |> put_in(["boot", "firmware", "bytes"], firmware_bytes)
        |> put_in(["root", "bytes"], root_bytes)
        |> put_in(["root", "sha256"], digest)
        |> Map.put("minimum_disk_bytes", root_bytes)
        |> Map.put("minimum_memory_bytes", memory)

      assert {:ok, image} = ImageManifest.validate(value)

      assert {:ok, ^image} =
               value |> JSON.encode!() |> JSON.decode!() |> ImageManifest.validate()

      for changed <- [
            %{value | "minimum_memory_bytes" => memory + 1},
            put_in(value, ["boot", "firmware", "bytes"], rem(firmware_bytes, 67_108_864) + 1),
            put_in(value, ["root", "sha256"], String.duplicate("f", 64))
          ] do
        {:ok, other} = ImageManifest.validate(changed)
        refute other.id == image.id or changed == value
      end

      {:ok, kernel} = ImageManifest.validate(manifest())
      refute kernel.id == image.id
      assert ImageManifest.guest_agents(image) == :none
      assert ImageManifest.root_artifact(image) == "disk.raw"
    end
  end

  describe "version 6 native manifests" do
    test "FreeBSD firmware shape validates for Firecracker's PVH loader" do
      manifest =
        illumos_manifest()
        |> Map.put("os", "freebsd")
        |> Map.put("guest_agents", "freebsd-v1")

      assert {:ok, image} = ImageManifest.validate(manifest)
      assert image.os == :freebsd
      assert image.boot_kind == :firmware
      assert image.guest_agents == :freebsd_v1
      assert image.root_format == :raw_gpt
      assert ImageManifest.file_names(image) == ["manifest.json", "firmware", "disk.raw"]

      assert {:ok, sourced} =
               ImageManifest.validate(Map.put(manifest, "workspace_source_version", 2))

      assert sourced.workspace_source_version == 2
      assert ImageManifest.workspace_source?(Map.put(manifest, "workspace_source_version", 2))
    end

    test "illumos firmware disk shape validates and has closed agent identity" do
      assert {:ok, image} = ImageManifest.validate(illumos_manifest())
      assert image.os == :illumos
      assert image.boot_kind == :firmware
      assert image.guest_agents == :illumos_v1
      assert ImageManifest.boot_artifacts(image) == ["firmware"]
      assert ImageManifest.root_artifact(image) == "disk.raw"
      assert ImageManifest.file_names(image) == ["manifest.json", "firmware", "disk.raw"]

      for invalid <- [
            Map.put(illumos_manifest(), "guest_agents", "freebsd-v1"),
            Map.put(illumos_manifest(), "name", "OmniOS"),
            Map.put(illumos_manifest(), "editor_platform", %{"version" => 1, "os" => "illumos"}),
            Map.put(illumos_manifest(), "version", 5),
            put_in(illumos_manifest(), ["boot", "pci"], false)
          ] do
        assert {:error, :invalid_image_manifest} = ImageManifest.validate(invalid)
      end
    end

    test "kernel provenance is required, bounded and identity-bearing" do
      base = illumos_manifest()
      assert {:ok, image} = ImageManifest.validate(base)
      assert image.kernel.source_revision == String.duplicate("1", 40)
      assert {:ok, normalized_kernel} = ImageManifest.kernel_provenance(base["kernel"])
      assert normalized_kernel == image.kernel

      for invalid <- [
            Map.delete(base, "kernel"),
            put_in(base, ["kernel", "source_revision"], String.duplicate("A", 40)),
            put_in(base, ["kernel", "patch_hash"], String.duplicate("a", 63)),
            put_in(base, ["kernel", "compiler"], "clang\n19"),
            put_in(base, ["kernel", "bytes"], 8_589_934_593),
            put_in(base, ["kernel", "unexpected"], true)
          ] do
        assert {:error, :invalid_image_manifest} = ImageManifest.validate(invalid)
      end

      {:ok, changed} =
        base
        |> put_in(["kernel", "configuration_hash"], String.duplicate("4", 64))
        |> ImageManifest.validate()

      refute changed.id == image.id
    end
  end
end
