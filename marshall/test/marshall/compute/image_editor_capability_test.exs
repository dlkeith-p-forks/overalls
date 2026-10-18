defmodule Marshall.Compute.ImageEditorCapabilityTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Marshall.Compute.Image

  @type descriptor :: %{
          String.t() => String.t() | pos_integer()
        }
  @type image_input :: %{id: String.t(), manifest: map()}

  # @cc [owner:ghuntley,label:verification;security] image-editor-identity-property
  # Generated valid releases MUST be accepted only with their content-bound image
  # ID and exact configured tuple. Changing commit, package release or manifest
  # content MUST refuse; catalog enabled status MUST NOT change that result.
  property "editor compatibility binds the complete immutable release and image identity" do
    descriptor = draw("descriptor", descriptor_gen())
    enabled = draw("enabled", boolean())
    platform = draw("platform", member_of([:linux, :windows]))
    image = editor_image(descriptor, platform) |> Map.put(:enabled, enabled)

    assert {:ok,
            %{
              editor_protocol: 1,
              editor_commit: commit,
              editor_release: release
            }} = Image.editor_capability(image, descriptor)

    assert commit == descriptor["commit"] and release == descriptor["release"]

    for key <- ["commit", "release"] do
      other = Map.update!(descriptor, key, &different_digest/1)
      assert {:error, :unsupported_image} = Image.editor_capability(image, other)
    end

    changed =
      case platform do
        :linux -> Map.update!(image.manifest, "boot_args", &(&1 <> " quiet"))
        :windows -> put_in(image.manifest, ["root", "sha256"], String.duplicate("d", 64))
      end

    assert {:error, :unavailable} =
             Image.editor_capability(%{image | manifest: changed}, descriptor)
  end

  test "a current image without an editor is unsupported, and malformed data fails closed" do
    descriptor = Marshall.EditorFixture.descriptor()
    manifest = Marshall.ComputeFixtures.image_manifest()
    {:ok, validated} = OverallsProtocol.ImageManifest.validate(manifest)
    assert {:error, :unsupported_image} = Image.editor_capability(validated, descriptor)

    for image <- [nil, %{}, %{id: validated.id, manifest: nil}, %{validated | id: "wrong"}] do
      assert {:error, :unavailable} = Image.editor_capability(image, descriptor)
    end

    image = editor_image(descriptor)

    for configured <- [nil, %{}, "release", Map.put(descriptor, "extra", true)] do
      assert {:error, :unavailable} = Image.editor_capability(image, configured)
    end
  end

  @spec descriptor_gen() :: Hegel.Gen.t(descriptor())
  defp descriptor_gen do
    gen all(commit <- binary(length: 20), release <- binary(length: 32)) do
      %{
        "protocol" => 1,
        "commit" => Base.encode16(commit, case: :lower),
        "release" => Base.encode16(release, case: :lower)
      }
    end
  end

  @spec editor_image(descriptor(), :linux | :windows) :: image_input()
  defp editor_image(descriptor, platform \\ :linux) do
    manifest =
      case platform do
        :linux ->
          Marshall.ComputeFixtures.image_manifest()
          |> Map.put("editor", descriptor)

        :windows ->
          Marshall.ComputeFixtures.windows_image_manifest()
          |> Map.merge(%{
            "version" => 7,
            "os" => "windows",
            "guest_agents" => "windows-editor-v1",
            "editor" => descriptor
          })
      end

    {:ok, validated} = OverallsProtocol.ImageManifest.validate(manifest)
    %{id: validated.id, manifest: manifest}
  end

  @spec different_digest(String.t()) :: String.t()
  defp different_digest("0" <> rest), do: "1" <> rest
  defp different_digest(<<_first, rest::binary>>), do: "0" <> rest
end
