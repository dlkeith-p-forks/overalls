defmodule Lilly.VM.WindowsEditorBundleTest do
  # This fixture owns the process-wide service uid; it runs without privilege.
  use ExUnit.Case, async: false
  alias Lilly.Host.{Image, Privilege}
  alias Lilly.VM.{Spec, WorkloadBundle}
  alias OverallsProtocol.ImageManifest

  @moduletag :tmp_dir
  @key {Privilege, :service_uid}

  setup %{tmp_dir: directory} do
    previous = :persistent_term.get(@key, nil)
    owner = File.stat!(directory).uid
    :persistent_term.put(@key, owner)

    on_exit(fn ->
      if previous == nil,
        do: :persistent_term.erase(@key),
        else: :persistent_term.put(@key, previous)
    end)

    :ok
  end

  # @cc [owner:ghuntley,label:verification;security] windows-editor-retained-bundle-roundtrip
  # An already materialized Windows editor placement MUST match the exact v4
  # editor descriptor on idempotent materialization and load. A changed tuple or
  # old Windows bundle under that image ID MUST refuse. Owned local files and
  # service-uid normalization do not establish native Windows or VM acceptance.
  test "retained firmware bundle preserves the exact Windows editor release", %{
    tmp_dir: directory
  } do
    {image, spec, metadata} = fixture(directory)
    marker = Path.join(directory, "boot-bundle.json")
    File.write!(marker, JSON.encode!(metadata))
    File.chmod!(marker, 0o600)

    assert :ok = WorkloadBundle.materialize(directory, image, spec)
    assert {:ok, bundle} = WorkloadBundle.load(directory, spec)
    assert bundle.editor == image.manifest.editor
    assert bundle.guest_agents == :windows_editor_v1
    assert bundle.git_identity_version == 1
    assert OverallsProtocol.WorkloadBundle.encode(bundle) == metadata
    assert WorkloadBundle.files(bundle) == ["firmware", "boot-bundle.json"]

    changed = put_in(image.manifest.editor.release, String.duplicate("c", 64))

    assert {:error, :workload_bundle_materialization_failed} =
             WorkloadBundle.materialize(directory, changed, spec)

    old =
      metadata
      |> Map.drop(["os", "editor"])
      |> Map.put("version", 2)
      |> Map.put("guest_agents", "windows-v1")

    File.write!(marker, JSON.encode!(old))

    assert {:error, :workload_bundle_materialization_failed} =
             WorkloadBundle.materialize(directory, image, spec)
  end

  @spec fixture(Path.t()) :: {Image.t(), Spec.t(), map()}
  defp fixture(directory) do
    bytes = "firmware"

    artifact = %{
      "bytes" => byte_size(bytes),
      "sha256" => :crypto.hash(:sha256, bytes) |> Base.encode16(case: :lower)
    }

    editor = %{
      "protocol" => 1,
      "commit" => String.duplicate("a", 40),
      "release" => String.duplicate("b", 64)
    }

    {:ok, manifest} =
      ImageManifest.validate(%{
        "version" => 7,
        "os" => "windows",
        "architecture" => "x86_64",
        "guest_agents" => "windows-editor-v1",
        "editor" => editor,
        "git_identity_version" => 1,
        "workspace_source_version" => 2,
        "boot" => %{"kind" => "firmware", "pci" => true, "firmware" => artifact},
        "root" => Map.put(artifact, "format", "raw-gpt"),
        "minimum_memory_bytes" => 536_870_912,
        "minimum_disk_bytes" => 2_147_483_648
      })

    firmware = Path.join(directory, "firmware")
    File.write!(firmware, bytes)
    File.chmod!(firmware, 0o444)

    image = %Image{
      id: manifest.id,
      path: directory,
      manifest: manifest,
      files: %{"firmware" => {firmware, File.stat!(firmware)}}
    }

    placement = Lilly.UUID.generate()
    {:ok, guest} = Lilly.Network.Guest.new(placement, :customer, 2)

    spec = %Spec{
      id: placement,
      image_id: image.id,
      pool_id: Lilly.UUID.generate(),
      network: guest,
      vcpu: 1,
      memory_bytes: 536_870_912,
      disk_bytes: 2_147_483_648
    }

    metadata = %{
      "version" => 4,
      "image_id" => image.id,
      "architecture" => "x86_64",
      "os" => "windows",
      "boot" => "firmware",
      "pci" => true,
      "guest_agents" => "windows-editor-v1",
      "editor" => editor,
      "git_identity_version" => 1,
      "firmware_bytes" => byte_size(bytes)
    }

    {image, spec, metadata}
  end
end
