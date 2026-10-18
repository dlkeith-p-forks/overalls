defmodule Lilly.VM.ImageSourceCapabilityTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.ImageManifest
  alias Lilly.Host.{Image, Pool}
  alias Lilly.VM.{Config, Driver, Spec}

  @moduletag :tmp_dir

  # @cc [owner:ghuntley,label:verification;security] source-image-refusal-before-host-effects
  # Calling the real driver with an absent, stale, malformed or identity-mismatched
  # source capability MUST return the fixed refusal before accessing native host
  # resources or creating any files; synthetic bytes cannot prove guest execution.
  @tag :hegel
  test "source images refuse before creating launch state", %{tmp_dir: directory} do
    check all(capability <- member_of([nil, 1, "2", true]), test_cases: 8) do
      {image, spec} = fixture(directory)
      raw = Map.put(image.manifest.manifest, "workspace_source_version", capability)
      image = put_in(image.manifest.manifest, raw)

      assert {:error, :workspace_source_unavailable} =
               Driver.start(config(directory), pool(directory, spec), image, spec)

      assert File.ls!(directory) == []
    end
  end

  test "obsolete manifest and image identity mismatch refuse before host effects", %{
    tmp_dir: directory
  } do
    {image, spec} = fixture(directory)

    for raw <- [
          Map.put(image.manifest.manifest, "version", 2),
          Map.put(image.manifest.manifest, "version", 3),
          Map.put(image.manifest.manifest, "boot_args", "changed boot")
        ] do
      stale = put_in(image.manifest.manifest, raw)

      assert {:error, :workspace_source_unavailable} =
               Driver.start(config(directory), pool(directory, spec), stale, spec)

      assert File.ls!(directory) == []
    end
  end

  test "source protocol alone cannot admit an unreviewed native image", %{tmp_dir: directory} do
    artifact_data = :binary.copy(<<0>>, 1024)
    artifact_digest = :crypto.hash(:sha256, artifact_data) |> Base.encode16(case: :lower)
    artifact = %{"bytes" => 1024, "sha256" => artifact_digest}

    {:ok, manifest} =
      ImageManifest.validate(%{
        "version" => 6,
        "os" => "freebsd",
        "architecture" => "x86_64",
        "boot" => %{"kind" => "firmware", "pci" => true, "firmware" => artifact},
        "kernel" => native_kernel(),
        "root" => Map.put(artifact, "format", "raw-gpt"),
        "minimum_memory_bytes" => 536_870_912,
        "minimum_disk_bytes" => 2_147_483_648,
        "guest_agents" => "freebsd-v1",
        "workspace_source_version" => 2
      })

    assert ImageManifest.workspace_source?(manifest.manifest)

    assert {:ok, illumos} =
             ImageManifest.validate(
               manifest.manifest
               |> Map.put("os", "illumos")
               |> Map.put("guest_agents", "illumos-v1")
             )

    assert ImageManifest.workspace_source?(illumos.manifest)

    {:ok, source} = OverallsProtocol.WorkspaceSource.parse_url("https://github.com/octo/demo")
    id = Lilly.UUID.generate()
    pool_id = Lilly.UUID.generate()
    {:ok, network} = Lilly.Network.Guest.new(id, :oss, 2)

    for name <- ["firmware", "disk.raw"] do
      File.write!(Path.join(directory, name), :binary.copy(<<0>>, 1024))
      File.chmod!(Path.join(directory, name), 0o444)
    end

    File.write!(Path.join(directory, "manifest.json"), JSON.encode!(manifest.manifest))
    File.chmod!(Path.join(directory, "manifest.json"), 0o444)
    {:ok, image} = Image.load(directory)

    spec = %Spec{
      id: id,
      image_id: image.id,
      pool_id: pool_id,
      network: network,
      vcpu: 1,
      memory_bytes: 536_870_912,
      disk_bytes: 2_147_483_648,
      workspace_source: source
    }

    before = File.ls!(directory)

    for validated <- [manifest, illumos] do
      candidate = %{image | id: validated.id, manifest: validated}
      candidate_spec = %{spec | image_id: validated.id}

      assert {:error, :guest_agents_unavailable} =
               Driver.start(
                 config(directory),
                 pool(directory, candidate_spec),
                 candidate,
                 candidate_spec
               )

      assert File.ls!(directory) == before
    end
  end

  @spec fixture(Path.t()) :: {Image.t(), Spec.t()}
  defp fixture(directory) do
    artifact = %{"bytes" => 1024, "sha256" => String.duplicate("a", 64)}

    {:ok, manifest} =
      ImageManifest.validate(%{
        "version" => 4,
        "workspace_source_version" => 2,
        "architecture" => "x86_64",
        "boot_args" => "console=ttyS0",
        "minimum_memory_bytes" => 536_870_912,
        "minimum_disk_bytes" => 2_147_483_648,
        "kernel" => artifact,
        "initrd" => artifact,
        "rootfs" => artifact
      })

    {:ok, source} = OverallsProtocol.WorkspaceSource.parse_url("https://github.com/octo/demo")
    id = Lilly.UUID.generate()
    pool_id = Lilly.UUID.generate()
    {:ok, network} = Lilly.Network.Guest.new(id, :oss, 2)

    image = %Image{id: manifest.id, path: directory, manifest: manifest, files: %{}}

    spec = %Spec{
      id: id,
      image_id: image.id,
      pool_id: pool_id,
      network: network,
      vcpu: 1,
      memory_bytes: 536_870_912,
      disk_bytes: 2_147_483_648,
      workspace_source: source
    }

    {image, spec}
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

  @spec config(Path.t()) :: Config.t()
  defp config(directory) do
    {:ok, network} = Lilly.Network.Config.new(Lilly.UUID.generate(), "eth0", [], directory)

    %Config{
      state_dir: directory,
      network: network,
      firecracker: "/unavailable/firecracker",
      jailer: "/unavailable/jailer",
      unshare: "/unavailable/unshare",
      launch_guard: "/unavailable/launch-guard",
      boot_log_writer: "/unavailable/boot-log-writer"
    }
  end

  @spec pool(Path.t(), Spec.t()) :: Pool.t()
  defp pool(directory, spec),
    do: %Pool{id: spec.pool_id, path: directory, filesystem_id: "zfs:1:2"}
end
