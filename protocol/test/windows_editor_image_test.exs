defmodule OverallsProtocol.WindowsEditorImageTest do
  use ExUnit.Case, async: true
  import Hegel, except: [draw: 2]
  import OverallsProtocol.TestProperties, only: [draw: 2]
  import Hegel.Gen
  alias OverallsProtocol.{GuestAgents, ImageManifest, NativeAdmission, WorkloadBundle}

  @type editor_wire :: %{String.t() => String.t() | pos_integer()}

  # @cc [owner:ghuntley,label:verification;security] windows-editor-identity-property
  # Generated Windows editor images MUST round-trip with every release and
  # boot/root requirement bound to the immutable v7 identity. The corresponding
  # portable v4 bundle MUST retain the exact descriptor without widening v5/v2.
  property "Windows editor identity binds its release and survives portable storage",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 2_001_710 do
    editor = draw("editor release", editor_gen())
    firmware_bytes = draw("firmware bytes", integer(1..67_108_863))
    root_bytes = draw("root bytes", integer(1..137_438_953_471))
    source = draw("workspace version", member_of([nil, 2]))
    git = draw("Git identity", boolean())

    value =
      manifest(editor)
      |> put_in(["boot", "firmware", "bytes"], firmware_bytes)
      |> put_in(["root", "bytes"], root_bytes)
      |> Map.put("workspace_source_version", source)

    value = if git, do: Map.put(value, "git_identity_version", 1), else: value
    assert {:ok, image} = ImageManifest.validate(value)
    assert ImageManifest.encode(image) == value
    assert {:ok, ^image} = value |> JSON.encode!() |> JSON.decode!() |> ImageManifest.validate()
    assert {:ok, image.editor} == ImageManifest.editor(value)
    assert ImageManifest.guest_agents(image) == :windows_editor_v1
    assert GuestAgents.capabilities(:windows_editor_v1, image).editor
    refute GuestAgents.capabilities(:windows_editor_v1, image).inception
    refute NativeAdmission.checkpoint_admitted?(image)
    assert ImageManifest.file_names(image) == ["manifest.json", "firmware", "disk.raw"]

    mutations = [
      put_in(value, ["editor", "commit"], different_digest(editor["commit"])),
      put_in(value, ["editor", "release"], different_digest(editor["release"])),
      put_in(value, ["boot", "firmware", "bytes"], firmware_bytes + 1),
      put_in(value, ["boot", "firmware", "sha256"], String.duplicate("d", 64)),
      put_in(value, ["root", "bytes"], root_bytes + 1),
      put_in(value, ["root", "sha256"], String.duplicate("e", 64)),
      Map.put(value, "minimum_memory_bytes", 2_147_483_649),
      Map.put(value, "minimum_disk_bytes", 137_438_953_473),
      Map.put(value, "workspace_source_version", if(source == nil, do: 2, else: nil))
    ]

    for mutated <- mutations do
      assert {:ok, changed} = ImageManifest.validate(mutated)
      refute changed.id == image.id
    end

    portable = bundle(image)
    assert {:ok, normalized} = WorkloadBundle.validate(portable)
    assert normalized.editor == image.editor
    assert WorkloadBundle.encode(normalized) == portable
    assert WorkloadBundle.files(normalized) == ["firmware"]
    assert GuestAgents.capabilities(:windows_editor_v1, normalized).editor

    assert {:ok, ^normalized} =
             portable |> JSON.encode!() |> JSON.decode!() |> WorkloadBundle.validate()
  end

  test "Windows editor manifests and bundles refuse missing, substituted and unknown fields" do
    value = manifest(editor())
    {:ok, image} = ImageManifest.validate(value)

    for malformed <- [
          Map.delete(value, "editor"),
          Map.put(value, "editor", nil),
          put_in(value, ["editor", "protocol"], 2),
          put_in(value, ["editor", "commit"], String.duplicate("A", 40)),
          put_in(value, ["editor", "extra"], true),
          Map.put(value, "guest_agents", "windows-v1"),
          Map.put(value, "os", "linux"),
          Map.put(value, "architecture", "aarch64"),
          Map.put(value, "workspace_source_version", 1),
          Map.put(value, "minimum_disk_bytes", 1023),
          Map.put(value, "kernel", %{}),
          Map.put(value, "version", 5),
          Map.put(value, "version", 6),
          put_in(value, ["boot", "pci"], false),
          put_in(value, ["boot", "extra"], true),
          put_in(value, ["boot", "firmware", "bytes"], 67_108_865),
          put_in(value, ["root", "format"], "ext4"),
          put_in(value, ["root", "extra"], true),
          put_in(value, ["root", "bytes"], 137_438_953_473)
        ] do
      assert {:error, :invalid_image_manifest} = ImageManifest.validate(malformed)
      assert {:error, :editor_unavailable} = ImageManifest.editor(malformed)
    end

    portable = bundle(image)

    for malformed <- [
          Map.delete(portable, "editor"),
          Map.put(portable, "editor", nil),
          put_in(portable, ["editor", "release"], String.duplicate("A", 64)),
          put_in(portable, ["editor", "extra"], true),
          Map.put(portable, "guest_agents", "windows-v1"),
          Map.put(portable, "os", "freebsd"),
          Map.put(portable, "architecture", "aarch64"),
          Map.put(portable, "boot", "kernel"),
          Map.put(portable, "pci", false),
          Map.put(portable, "firmware_bytes", 0),
          Map.put(portable, "firmware_bytes", 67_108_865),
          Map.put(portable, "image_id", "sha256:" <> String.duplicate("A", 64)),
          Map.put(portable, "kernel_bytes", 1),
          Map.put(portable, "version", 2)
        ] do
      assert {:error, :invalid_workload_bundle} = WorkloadBundle.validate(malformed)
    end
  end

  test "the version-7 ordered identity has a fixed independent SHA-256 vector" do
    assert {:ok, image} = ImageManifest.validate(manifest(editor()))

    assert image.id ==
             "sha256:eb53042e9ffcea68876e0555cf57d74f950a5e09829cb12bb2bd29e18f131a07"
  end

  test "legacy Windows rows remain editor false and context cannot substitute for a descriptor" do
    value =
      manifest(editor())
      |> Map.drop(["os", "editor"])
      |> Map.put("version", 5)
      |> Map.put("guest_agents", "windows-v1")

    assert {:ok, old} = ImageManifest.validate(value)
    refute GuestAgents.capabilities(:windows_v1, old).editor
    assert {:error, :editor_unavailable} = ImageManifest.editor(value)

    for malformed <- [
          Map.put(value, "editor", editor()),
          Map.put(value, "guest_agents", "windows-editor-v1")
        ] do
      assert {:error, :invalid_image_manifest} = ImageManifest.validate(malformed)
    end

    {:ok, image} = ImageManifest.validate(manifest(editor()))

    for context <- [
          nil,
          %{guest_agents: :windows_editor_v1},
          Map.delete(image, :editor),
          %{image | guest_agents: :windows_v1},
          %{image | os: :linux},
          %{image | boot_kind: :kernel},
          %{image | pci: false},
          put_in(image, [:editor, :extra], true),
          put_in(image, [:editor, :release], String.duplicate("A", 64))
        ] do
      refute GuestAgents.capabilities(:windows_editor_v1, context) |> Map.values() |> Enum.any?()
    end
  end

  @spec manifest(editor_wire()) :: map()
  defp manifest(editor) do
    %{
      "version" => 7,
      "os" => "windows",
      "architecture" => "x86_64",
      "boot" => %{
        "kind" => "firmware",
        "pci" => true,
        "firmware" => %{"bytes" => 4_194_304, "sha256" => String.duplicate("b", 64)}
      },
      "root" => %{
        "format" => "raw-gpt",
        "bytes" => 1024,
        "sha256" => String.duplicate("c", 64)
      },
      "guest_agents" => "windows-editor-v1",
      "minimum_memory_bytes" => 2_147_483_648,
      "minimum_disk_bytes" => 137_438_953_472,
      "workspace_source_version" => 2,
      "editor" => editor
    }
  end

  @spec bundle(ImageManifest.windows_editor_image()) :: map()
  defp bundle(image) do
    base = %{
      "version" => 4,
      "image_id" => image.id,
      "architecture" => "x86_64",
      "os" => "windows",
      "boot" => "firmware",
      "pci" => true,
      "guest_agents" => "windows-editor-v1",
      "firmware_bytes" => image.manifest["boot"]["firmware"]["bytes"],
      "editor" => image.manifest["editor"]
    }

    if Map.get(image, :git_identity_version) == 1,
      do: Map.put(base, "git_identity_version", 1),
      else: base
  end

  @spec editor() :: editor_wire()
  defp editor do
    %{
      "protocol" => 1,
      "commit" => String.duplicate("a", 40),
      "release" => String.duplicate("b", 64)
    }
  end

  @spec editor_gen() :: Hegel.Gen.t(editor_wire())
  defp editor_gen do
    gen all(commit <- binary(length: 20), release <- binary(length: 32)) do
      %{
        "protocol" => 1,
        "commit" => Base.encode16(commit, case: :lower),
        "release" => Base.encode16(release, case: :lower)
      }
    end
  end

  @spec different_digest(String.t()) :: String.t()
  defp different_digest("0" <> rest), do: "1" <> rest
  defp different_digest(<<_first, rest::binary>>), do: "0" <> rest
end
