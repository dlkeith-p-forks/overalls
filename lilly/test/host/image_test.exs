defmodule Lilly.Host.ImageTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Host.Image
  @moduletag :tmp_dir

  setup %{tmp_dir: directory} do
    File.chmod!(directory, 0o700)

    artifacts =
      Map.new(["kernel", "initrd", "rootfs"], fn name ->
        data = "synthetic #{name}"
        path = Path.join(directory, if(name == "rootfs", do: "rootfs.ext4", else: name))
        File.write!(path, data)
        File.chmod!(path, 0o444)

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
    %{path: directory}
  end

  test "verified read-only artifacts advertise an identity; replacement removes availability", %{
    path: path
  } do
    assert {:ok, image} = Image.load(path)
    assert Image.available_ids([image]) == [image.id]
    kernel = Path.join(path, "kernel")
    File.rename!(kernel, kernel <> ".old")
    File.write!(kernel, "synthetic kernel")
    File.chmod!(kernel, 0o444)
    assert Image.available_ids([image]) == []
    File.rm!(kernel <> ".old")
    assert {:ok, replacement} = Image.load(path)
    assert replacement.id == image.id
  end

  test "digest mismatch, writable artifacts and missing files reject the whole image", %{
    path: path
  } do
    kernel = Path.join(path, "kernel")
    File.chmod!(kernel, 0o644)
    assert {:error, :invalid_local_image} = Image.load(path)
    File.write!(kernel, "corrupted kernel")
    File.chmod!(kernel, 0o444)
    assert {:error, :invalid_local_image} = Image.load(path)
    File.rm!(kernel)
    assert {:error, :invalid_local_image} = Image.load(path)
  end

  test "staged images skip only digests, are never advertised and still reject unsafe shapes", %{
    path: path
  } do
    assert {:ok, %Image{verified: true} = verified} = Image.load(path)
    assert {:ok, %Image{verified: false} = staged} = Image.stage(path)
    assert staged.id == verified.id and staged.files == verified.files
    assert Image.available_ids([staged]) == []
    assert Image.available_ids([verified]) == [verified.id]

    kernel = Path.join(path, "kernel")
    File.rename!(kernel, kernel <> ".old")
    File.write!(kernel, "SYNTHETIC kernel")
    File.chmod!(kernel, 0o444)
    File.rm!(kernel <> ".old")
    assert {:ok, %Image{verified: false}} = Image.stage(path)
    assert {:error, :invalid_local_image} = Image.load(path)

    File.chmod!(kernel, 0o644)
    assert {:error, :invalid_local_image} = Image.stage(path)
    File.write!(kernel, "short")
    File.chmod!(kernel, 0o444)
    assert {:error, :invalid_local_image} = Image.stage(path)
    File.rm!(kernel)
    assert {:error, :invalid_local_image} = Image.stage(path)
    assert {:error, :invalid_local_image} = Image.stage("relative")
  end

  test "read-only symlink artifacts work while unsafe target ancestry fails", %{path: path} do
    kernel = Path.join(path, "kernel")
    target = Path.join(Path.dirname(path), "objects-" <> Lilly.UUID.generate())
    File.mkdir!(target)
    File.rename!(kernel, Path.join(target, "kernel"))
    File.ln_s!(Path.join(target, "kernel"), kernel)
    assert {:ok, image} = Image.load(path)
    File.chmod!(target, 0o777)
    refute Image.unchanged?(image)
    assert {:error, :invalid_local_image} = Image.load(path)
  end

  describe "firmware images" do
    setup %{tmp_dir: directory} do
      path = Path.join(directory, "firmware-image")
      File.mkdir!(path)
      File.chmod!(path, 0o700)

      write = fn name, data ->
        File.write!(Path.join(path, name), data)
        File.chmod!(Path.join(path, name), 0o444)

        %{
          "bytes" => byte_size(data),
          "sha256" => :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
        }
      end

      firmware = write.("firmware", "synthetic PVH firmware")
      disk = write.("disk.raw", "synthetic GPT disk image")

      manifest = %{
        "version" => 5,
        "architecture" => "x86_64",
        "boot" => %{"kind" => "firmware", "pci" => true, "firmware" => firmware},
        "root" => Map.put(disk, "format", "raw-gpt"),
        "guest_agents" => "none",
        "minimum_memory_bytes" => 2_147_483_648,
        "minimum_disk_bytes" => 34_359_738_368,
        "workspace_source_version" => nil
      }

      File.write!(Path.join(path, "manifest.json"), JSON.encode!(manifest))
      File.chmod!(Path.join(path, "manifest.json"), 0o444)
      %{firmware_path: path}
    end

    test "verify exactly firmware and disk.raw and expose their names", %{firmware_path: path} do
      assert {:ok, image} = Image.load(path)
      assert image.manifest.boot_kind == :firmware
      assert image.manifest.guest_agents == :none
      assert Enum.sort(Map.keys(image.files)) == ["disk.raw", "firmware", "manifest.json"]
      assert Image.root_artifact(image) == "disk.raw"
      assert Enum.sort(Image.file_names(image)) == ["disk.raw", "firmware", "manifest.json"]
      assert Image.available_ids([image]) == [image.id]
      assert {:ok, %Image{verified: false} = staged} = Image.stage(path)
      assert staged.id == image.id

      assert ["auto", _, "/tmp/target", "24"] =
               Image.copy_arguments(image, "disk.raw", "/tmp/target")
    end

    test "a stray kernel or a corrupted disk rejects the firmware image", %{firmware_path: path} do
      disk = Path.join(path, "disk.raw")
      File.chmod!(disk, 0o644)
      assert {:error, :invalid_local_image} = Image.load(path)
      File.write!(disk, "corrupted GPT disk image")
      File.chmod!(disk, 0o444)
      assert {:error, :invalid_local_image} = Image.load(path)
      assert {:ok, %Image{verified: false}} = Image.stage(path)
      File.chmod!(disk, 0o644)
      File.write!(disk, "synthetic GPT disk image")
      File.chmod!(disk, 0o444)
      assert {:ok, _} = Image.load(path)
      File.rm!(Path.join(path, "firmware"))
      assert {:error, :invalid_local_image} = Image.load(path)
    end

    # Windows images ship build evidence beside their artifacts; production
    # images failed to load when the file set was closed without it.
    test "a firmware image may carry an evidence directory, but not an evidence file", %{
      firmware_path: path
    } do
      evidence = Path.join(path, "evidence")
      File.mkdir!(evidence)
      File.write!(Path.join(evidence, "partitions.json"), "{}")
      assert {:ok, _} = Image.load(path)

      File.rm_rf!(evidence)
      File.write!(evidence, "not a directory")
      assert {:error, :invalid_local_image} = Image.load(path)
      File.rm!(evidence)
    end

    test "an artifact outside the validated firmware file set rejects the image", %{
      firmware_path: path
    } do
      stray = Path.join(path, "kernel")
      File.write!(stray, "unexpected kernel")
      File.chmod!(stray, 0o444)

      assert {:error, :invalid_local_image} = Image.load(path)
    end
  end

  describe "native image artifacts" do
    test "FreeBSD uses its complete GPT disk as the source root artifact", %{tmp_dir: directory} do
      path = write_native_image(directory, :freebsd)

      assert {:ok, image} = Image.load(path)
      assert image.manifest.os == :freebsd
      assert Image.root_artifact(image) == "disk.raw"
      assert Enum.sort(Image.file_names(image)) == ["disk.raw", "firmware", "manifest.json"]

      assert ["auto", source, "/tmp/rootfs.ext4", "16"] =
               Image.copy_arguments(image, "disk.raw", "/tmp/rootfs.ext4")

      assert source == Path.join(path, "disk.raw")
    end

    test "FreeBSD rejects an artifact outside its firmware/disk file set", %{tmp_dir: directory} do
      path = write_native_image(directory, :freebsd)
      stray = Path.join(path, "kernel")
      File.write!(stray, "unexpected kernel")
      File.chmod!(stray, 0o444)

      assert {:error, :invalid_local_image} = Image.load(path)
    end

    test "illumos uses disk.raw as the source root artifact", %{tmp_dir: directory} do
      path = write_native_image(directory, :illumos)

      assert {:ok, image} = Image.load(path)
      assert image.manifest.os == :illumos
      assert Image.root_artifact(image) == "disk.raw"
      assert Enum.sort(Image.file_names(image)) == ["disk.raw", "firmware", "manifest.json"]

      assert ["auto", source, "/tmp/rootfs.ext4", "12"] =
               Image.copy_arguments(image, "disk.raw", "/tmp/rootfs.ext4")

      assert source == Path.join(path, "disk.raw")
    end

    test "illumos rejects an artifact outside its firmware/disk file set", %{tmp_dir: directory} do
      path = write_native_image(directory, :illumos)
      stray = Path.join(path, "kernel")
      File.write!(stray, "unexpected kernel")
      File.chmod!(stray, 0o444)

      assert {:error, :invalid_local_image} = Image.load(path)
    end
  end

  @spec write_native_image(Path.t(), :freebsd | :illumos) :: Path.t()
  defp write_native_image(directory, :freebsd) do
    path = Path.join(directory, "freebsd-image")
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    firmware = write_artifact(path, "firmware", "freebsd firmware")
    root = write_artifact(path, "disk.raw", "freebsd GPT disk")

    write_manifest(path, %{
      "version" => 6,
      "os" => "freebsd",
      "architecture" => "x86_64",
      "boot" => %{"kind" => "firmware", "pci" => true, "firmware" => firmware},
      "root" => Map.put(root, "format", "raw-gpt"),
      "kernel" => native_kernel(),
      "minimum_memory_bytes" => 536_870_912,
      "minimum_disk_bytes" => 8_589_934_592,
      "guest_agents" => "freebsd-v1",
      "workspace_source_version" => nil
    })

    path
  end

  defp write_native_image(directory, :illumos) do
    path = Path.join(directory, "illumos-image")
    File.mkdir!(path)
    File.chmod!(path, 0o700)
    firmware = write_artifact(path, "firmware", "illumos firmware")
    root = write_artifact(path, "disk.raw", "illumos disk")

    write_manifest(path, %{
      "version" => 6,
      "os" => "illumos",
      "architecture" => "x86_64",
      "boot" => %{"kind" => "firmware", "pci" => true, "firmware" => firmware},
      "root" => Map.put(root, "format", "raw-gpt"),
      "kernel" => native_kernel(),
      "guest_agents" => "illumos-v1",
      "minimum_memory_bytes" => 536_870_912,
      "minimum_disk_bytes" => 8_589_934_592,
      "workspace_source_version" => nil
    })

    path
  end

  @spec write_artifact(Path.t(), String.t(), binary()) :: map()
  defp write_artifact(path, name, data) do
    artifact_path = Path.join(path, name)
    File.write!(artifact_path, data)
    File.chmod!(artifact_path, 0o444)

    %{
      "bytes" => byte_size(data),
      "sha256" => :crypto.hash(:sha256, data) |> Base.encode16(case: :lower)
    }
  end

  defp native_kernel do
    %{
      "bytes" => 1_048_576,
      "sha256" => String.duplicate("d", 64),
      "source_revision" => String.duplicate("1", 40),
      "patch_hash" => String.duplicate("2", 64),
      "configuration_hash" => String.duplicate("3", 64),
      "compiler" => "clang-19.1.7"
    }
  end

  @spec write_manifest(Path.t(), map()) :: :ok
  defp write_manifest(path, manifest) do
    manifest_path = Path.join(path, "manifest.json")
    File.write!(manifest_path, JSON.encode!(manifest))
    File.chmod!(manifest_path, 0o444)
  end

  describe "sealed identities" do
    # @cc [owner:ghuntley,label:verification;recovery] sealed-identity-remount-tests
    # A remount's new device number MUST NOT break a seal; any other changed
    # field, or a missing or extra file, MUST.
    property "only the device number may differ across a remount" do
      check all(
              names <- uniq_list_of(string(:alphanumeric, min_length: 1), min: 1, max: 16),
              values <- list_of(non_negative_integer(), length: 11),
              device <- non_negative_integer(),
              field <- integer(1..10),
              bump <- positive_integer()
            ) do
        expected = Map.new(names, &{&1, values})
        remounted = Map.new(names, &{&1, List.replace_at(values, 0, device)})
        assert Image.same_files?(remounted, expected)

        [name | _] = names
        changed = Map.update!(expected, name, &List.update_at(&1, field, fn v -> v + bump end))
        refute Image.same_files?(changed, expected)
        refute Image.same_files?(Map.delete(expected, name), expected)
        refute Image.same_files?(Map.put(expected, name <> ".extra", values), expected)
        refute Image.same_files?(Map.put(expected, name, Enum.take(values, 10)), expected)
      end
    end
  end

  describe "digest cache" do
    # @cc [owner:ghuntley,label:verification;security] digest-cache-exact-identity-tests
    # A recorded entry MUST be reused only for the exact path, manifest ID and
    # native identities; a replaced file or a non-private cache MUST force a
    # full hash, and a failed hash MUST never be recorded.
    test "an unchanged image is reused; a replaced file is hashed again", %{
      path: path,
      tmp_dir: _dir
    } do
      cache = Path.join([Path.dirname(path), "state", "images", "digests.json"])
      assert {:ok, %Image{verified: true} = first} = Image.load_cached(path, cache)
      assert %File.Stat{mode: mode} = File.stat!(cache)
      assert Bitwise.band(mode, 0o777) == 0o600
      assert {:ok, %Image{verified: true, id: id}} = Image.load_cached(path, cache)
      assert id == first.id

      # A same-content replacement changes the identity: hashed again, still valid.
      kernel = Path.join(path, "kernel")
      File.rename!(kernel, kernel <> ".old")
      File.write!(kernel, "synthetic kernel")
      File.chmod!(kernel, 0o444)
      File.rm!(kernel <> ".old")
      assert {:ok, %Image{verified: true}} = Image.load_cached(path, cache)

      # A corrupted replacement fails the hash and is not recorded.
      File.rm!(kernel)
      File.write!(kernel, "corrupted kernel")
      File.chmod!(kernel, 0o444)
      assert {:error, :invalid_local_image} = Image.load_cached(path, cache)

      refute JSON.decode!(File.read!(cache))[path]["identities"] ==
               elem(Image.identities(elem(Image.stage(path), 1)), 1)
    end

    test "a hit skips hashing only through a private cache", %{path: path} do
      # Corrupt bytes so that only a cache hit could report the image verified.
      kernel = Path.join(path, "kernel")
      File.rm!(kernel)
      File.write!(kernel, "corrupted kernel")
      File.chmod!(kernel, 0o444)
      assert {:error, :invalid_local_image} = Image.load(path)

      {:ok, staged} = Image.stage(path)
      {:ok, identities} = Image.identities(staged)
      cache = Path.join(Path.dirname(path), "digests.json")
      entry = JSON.encode!(%{path => %{"id" => staged.id, "identities" => identities}})

      File.write!(cache, entry)
      File.chmod!(cache, 0o644)
      assert {:error, :invalid_local_image} = Image.load_cached(path, cache)

      File.chmod!(cache, 0o600)
      assert {:ok, %Image{verified: true}} = Image.load_cached(path, cache)
    end
  end
end
