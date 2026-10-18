defmodule Lilly.VM.ImageGitIdentityCapabilityTest do
  use ExUnit.Case, async: true
  require Hegel
  import Hegel.Gen
  alias Lilly.Host.{Image, Pool}
  alias Lilly.VM.{Config, Driver, Spec}

  @moduletag :tmp_dir

  # @cc [owner:ghuntley,label:verification;security] git-identity-refusal-before-host-effects
  # Absent, invalid and identity-mismatched image capability MUST refuse through
  # the real driver before any launch files or native host effects are attempted.
  # These synthetic images do not establish guest execution or rollout evidence.
  @tag :hegel
  test "Git identity requires a matching explicit image capability before launch", %{
    tmp_dir: directory
  } do
    Hegel.check(
      fn test_case ->
        capability =
          :hegel.draw(
            test_case,
            "unsupported capability",
            member_of([:absent, nil, 0, 2, "1", true])
          )

        {image, spec} = fixture(directory)

        raw =
          if capability == :absent,
            do: Map.delete(image.manifest.manifest, "git_identity_version"),
            else: Map.put(image.manifest.manifest, "git_identity_version", capability)

        changed = put_in(image.manifest.manifest, raw)

        assert {:error, :git_identity_unavailable} =
                 Driver.start(config(directory), pool(directory, spec), changed, spec)

        assert {:error, :git_identity_unavailable} =
                 Driver.start(
                   config(directory),
                   pool(directory, spec),
                   image,
                   %{spec | image_id: "sha256:" <> String.duplicate("b", 64)}
                 )

        assert File.ls!(directory) == []
      end,
      database: :disabled,
      print_blob: false,
      test_cases: 100,
      seed: 814_029_313
    )
  end

  @spec fixture(Path.t()) :: {Image.t(), Spec.t()}
  defp fixture(directory) do
    artifact = %{"bytes" => 1024, "sha256" => String.duplicate("a", 64)}

    {:ok, manifest} =
      OverallsProtocol.ImageManifest.validate(%{
        "version" => 4,
        "workspace_source_version" => nil,
        "git_identity_version" => 1,
        "architecture" => "x86_64",
        "boot_args" => "console=ttyS0",
        "minimum_memory_bytes" => 536_870_912,
        "minimum_disk_bytes" => 2_147_483_648,
        "kernel" => artifact,
        "initrd" => artifact,
        "rootfs" => artifact
      })

    id = Lilly.UUID.generate()
    pool_id = Lilly.UUID.generate()
    {:ok, network} = Lilly.Network.Guest.new(id, :standard, 2)

    {:ok, identity} =
      OverallsProtocol.GitIdentity.validate(%{name: "Author", email: "author@example.test"})

    image = %Image{id: manifest.id, path: directory, manifest: manifest, files: %{}}

    spec = %Spec{
      id: id,
      image_id: image.id,
      pool_id: pool_id,
      network: network,
      vcpu: 1,
      memory_bytes: 536_870_912,
      disk_bytes: 2_147_483_648,
      git_identity: identity
    }

    {image, spec}
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
