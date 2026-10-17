defmodule OverallsProtocol.WorkloadBundleTest do
  use ExUnit.Case, async: true
  import Hegel, except: [draw: 2]
  import OverallsProtocol.TestProperties, only: [draw: 2]
  import Hegel.Gen
  alias OverallsProtocol.WorkloadBundle

  @image_id "sha256:" <> String.duplicate("a", 64)

  test "validates and encodes closed portable metadata without digests" do
    value = %{
      "version" => 1,
      "image_id" => @image_id,
      "architecture" => "x86_64",
      "boot_args" => "console=ttyS0 reboot=k panic=1 pci=off",
      "kernel_bytes" => 1,
      "initrd_bytes" => 536_870_912
    }

    assert {:ok, bundle} = WorkloadBundle.validate(value)
    assert %{boot_kind: :kernel, guest_agents: :linux} = bundle
    assert WorkloadBundle.encode(bundle) == value
    assert WorkloadBundle.files(bundle) == ["kernel", "initrd"]
    refute Map.has_key?(value, "sha256")
    assert WorkloadBundle.storage_bytes() == 1_073_741_824
  end

  test "version-1 encoding is pinned to exactly six keys" do
    {:ok, bundle} =
      WorkloadBundle.validate(%{
        "version" => 1,
        "image_id" => @image_id,
        "architecture" => "x86_64",
        "boot_args" => "console=ttyS0",
        "kernel_bytes" => 7,
        "initrd_bytes" => 9
      })

    assert JSON.encode!(WorkloadBundle.encode(bundle)) |> JSON.decode!() ==
             %{
               "version" => 1,
               "image_id" => @image_id,
               "architecture" => "x86_64",
               "boot_args" => "console=ttyS0",
               "kernel_bytes" => 7,
               "initrd_bytes" => 9
             }
  end

  test "rejects extra fields and out-of-bounds artifacts" do
    base = %{
      "version" => 1,
      "image_id" => @image_id,
      "architecture" => "x86_64",
      "boot_args" => "console=ttyS0",
      "kernel_bytes" => 1,
      "initrd_bytes" => 1
    }

    assert {:error, :invalid_workload_bundle} =
             WorkloadBundle.validate(Map.put(base, "kernel_sha256", String.duplicate("b", 64)))

    assert {:error, :invalid_workload_bundle} =
             WorkloadBundle.validate(%{base | "kernel_bytes" => 536_870_913})

    assert {:error, :invalid_workload_bundle} =
             WorkloadBundle.validate(%{
               base
               | "kernel_bytes" => 536_870_912,
                 "initrd_bytes" => 536_870_912
             })

    # A kernel bundle cannot become a firmware bundle by renumbering.
    assert {:error, :invalid_workload_bundle} =
             WorkloadBundle.validate(Map.put(base, "version", 2))
  end

  describe "version 2 firmware bundles" do
    defp firmware_bundle do
      %{
        "version" => 2,
        "image_id" => @image_id,
        "architecture" => "x86_64",
        "boot" => "firmware",
        "pci" => true,
        "guest_agents" => "none",
        "firmware_bytes" => 4_194_304
      }
    end

    test "validates and encodes exactly the seven version-2 keys" do
      assert {:ok, bundle} = WorkloadBundle.validate(firmware_bundle())

      assert bundle == %{
               image_id: @image_id,
               architecture: :x86_64,
               boot_kind: :firmware,
               guest_agents: :none,
               pci: true,
               firmware_bytes: 4_194_304
             }

      assert WorkloadBundle.encode(bundle) == firmware_bundle()
      assert WorkloadBundle.files(bundle) == ["firmware"]
      assert WorkloadBundle.file_sets() == [["kernel", "initrd"], ["kernel"], ["firmware"]]
    end

    test "refuses kernel fields, other kinds, agents, transports and bounds" do
      base = firmware_bundle()

      for value <- [
            Map.put(base, "boot_args", "console=ttyS0"),
            Map.put(base, "kernel_bytes", 1),
            Map.put(base, "initrd_bytes", 1),
            Map.put(base, "firmware_sha256", String.duplicate("b", 64)),
            Map.put(base, "boot", "kernel"),
            Map.put(base, "pci", false),
            Map.put(base, "guest_agents", "linux"),
            Map.put(base, "architecture", "aarch64"),
            Map.put(base, "image_id", "sha256:" <> String.duplicate("A", 64)),
            Map.put(base, "firmware_bytes", 0),
            Map.put(base, "firmware_bytes", 67_108_865),
            Map.put(base, "firmware_bytes", "4194304"),
            Map.delete(base, "guest_agents"),
            Map.put(base, "version", 1)
          ] do
        assert {:error, :invalid_workload_bundle} = WorkloadBundle.validate(value),
               "expected refusal for #{inspect(value)}"
      end
    end

    test "the windows-v1 agent set round-trips and other sets are refused" do
      windows = Map.put(firmware_bundle(), "guest_agents", "windows-v1")
      assert {:ok, bundle} = WorkloadBundle.validate(windows)
      assert bundle.guest_agents == :windows_v1
      assert WorkloadBundle.encode(bundle) == windows
      assert WorkloadBundle.files(bundle) == ["firmware"]

      for agents <- ["linux", "windows", "none ", nil] do
        assert {:error, :invalid_workload_bundle} =
                 WorkloadBundle.validate(Map.put(firmware_bundle(), "guest_agents", agents))
      end
    end

    property "every bounded firmware length round-trips and never encodes as version 1",
      database: :disabled,
      print_blob: false,
      test_cases: 100,
      seed: 563_997_434 do
      bytes = draw("bytes", integer(1..67_108_864))
      value = Map.put(firmware_bundle(), "firmware_bytes", bytes)
      assert {:ok, bundle} = WorkloadBundle.validate(value)
      assert WorkloadBundle.encode(bundle) == value
      assert WorkloadBundle.encode(bundle)["version"] == 2
      refute Map.has_key?(WorkloadBundle.encode(bundle), "boot_args")
    end
  end

  describe "version 3 native bundles" do
    defp kernel do
      %{
        "bytes" => 1_048_576,
        "sha256" => String.duplicate("d", 64),
        "source_revision" => String.duplicate("1", 40),
        "patch_hash" => String.duplicate("2", 64),
        "configuration_hash" => String.duplicate("3", 64),
        "compiler" => "clang-19.1.7"
      }
    end

    defp illumos_bundle do
      %{
        "version" => 3,
        "image_id" => @image_id,
        "architecture" => "x86_64",
        "os" => "illumos",
        "boot" => "firmware",
        "pci" => true,
        "guest_agents" => "illumos-v1",
        "firmware_bytes" => 4_194_304,
        "kernel" => kernel()
      }
    end

    defp freebsd_firmware_bundle do
      %{
        "version" => 3,
        "image_id" => @image_id,
        "architecture" => "x86_64",
        "os" => "freebsd",
        "boot" => "firmware",
        "pci" => true,
        "guest_agents" => "freebsd-v1",
        "firmware_bytes" => 4_194_304,
        "kernel" => kernel()
      }
    end

    test "FreeBSD firmware bundle is closed and round trips" do
      assert {:ok, bundle} = WorkloadBundle.validate(freebsd_firmware_bundle())
      assert bundle.os == :freebsd
      assert bundle.boot_kind == :firmware
      assert bundle.guest_agents == :freebsd_v1
      assert WorkloadBundle.encode(bundle) == freebsd_firmware_bundle()
      assert WorkloadBundle.files(bundle) == ["firmware"]

      for invalid <- [
            Map.put(freebsd_firmware_bundle(), "os", "illumos"),
            Map.put(freebsd_firmware_bundle(), "guest_agents", "illumos-v1"),
            Map.put(freebsd_firmware_bundle(), "extra", true),
            Map.put(freebsd_firmware_bundle(), "pci", false),
            Map.put(freebsd_firmware_bundle(), "firmware_bytes", 0)
          ] do
        assert {:error, :invalid_workload_bundle} = WorkloadBundle.validate(invalid)
      end
    end

    test "illumos firmware bundle is distinct and closed" do
      assert {:ok, bundle} = WorkloadBundle.validate(illumos_bundle())

      assert bundle == %{
               image_id: @image_id,
               architecture: :x86_64,
               boot_kind: :firmware,
               os: :illumos,
               guest_agents: :illumos_v1,
               pci: true,
               firmware_bytes: 4_194_304,
               kernel: %{
                 bytes: 1_048_576,
                 sha256: String.duplicate("d", 64),
                 source_revision: String.duplicate("1", 40),
                 patch_hash: String.duplicate("2", 64),
                 configuration_hash: String.duplicate("3", 64),
                 compiler: "clang-19.1.7"
               }
             }

      assert WorkloadBundle.encode(bundle) == illumos_bundle()
      assert WorkloadBundle.files(bundle) == ["firmware"]

      for value <- [
            Map.put(illumos_bundle(), "os", "freebsd"),
            Map.put(illumos_bundle(), "guest_agents", "freebsd-v1"),
            Map.put(illumos_bundle(), "extra", true),
            Map.put(illumos_bundle(), "version", 2),
            Map.put(illumos_bundle(), "pci", false),
            Map.put(illumos_bundle(), "boot", "kernel"),
            Map.put(illumos_bundle(), "firmware_bytes", 0),
            Map.put(illumos_bundle(), "firmware_bytes", 67_108_865),
            Map.put(illumos_bundle(), "architecture", "aarch64")
          ] do
        assert {:error, :invalid_workload_bundle} = WorkloadBundle.validate(value)
      end
    end
  end
end
