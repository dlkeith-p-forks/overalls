defmodule Lilly.Host.ImageTemplateCacheableTest do
  use ExUnit.Case, async: true
  alias Lilly.Host.{Image, ImageTemplate, Pool}
  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    File.chmod!(directory, 0o700)

    artifacts =
      Map.new(["kernel", "initrd", "rootfs"], fn name ->
        data = String.duplicate("#{name} ", 64)
        file = Path.join(directory, if(name == "rootfs", do: "rootfs.ext4", else: name))
        File.write!(file, data)
        File.chmod!(file, 0o444)

        {name,
         %{
           "bytes" => byte_size(data),
           "sha256" => :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
         }}
      end)

    manifest =
      Map.merge(artifacts, %{
        "version" => 4,
        "workspace_source_version" => nil,
        "architecture" => "x86_64",
        "boot_args" => "console=ttyS0",
        "minimum_memory_bytes" => 536_870_912,
        "minimum_disk_bytes" => 2_147_483_648
      })

    File.write!(Path.join(directory, "manifest.json"), JSON.encode!(manifest))
    File.chmod!(Path.join(directory, "manifest.json"), 0o444)
    {:ok, image} = Image.stage(directory)
    # The template charge counts every staged file, the manifest included.
    total = Enum.sum(for {_, {_, stat}} <- image.files, do: stat.size)
    artifact_total = artifacts |> Map.values() |> Enum.map(& &1["bytes"]) |> Enum.sum()
    assert total == artifact_total + File.stat!(Path.join(directory, "manifest.json")).size
    %{image: image, total: total, directory: directory}
  end

  defp pool(directory, budget) do
    %Pool{
      id: Lilly.UUID.generate(),
      path: directory,
      filesystem_id: "zfs:1:2",
      template_budget_bytes: budget
    }
  end

  # @cc [owner:ghuntley,label:verification;capacity] template-cacheable-size-only
  # cacheable?/2 MUST compare the staged artifact bytes with the pool budget and
  # nothing else: a staged (unverified) image decides without hashing, the exact
  # budget fits, and one byte less does not.
  test "cacheability is the artifact size against the pool budget, without hashing", c do
    refute c.image.verified
    assert ImageTemplate.cacheable?(pool(c.directory, c.total), c.image)
    assert ImageTemplate.cacheable?(pool(c.directory, c.total + 1), c.image)
    refute ImageTemplate.cacheable?(pool(c.directory, c.total - 1), c.image)
  end
end
