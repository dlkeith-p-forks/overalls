defmodule Lilly.Control.ConfigTest do
  use ExUnit.Case, async: true
  alias Lilly.Control.Config
  @moduletag :tmp_dir
  @id "11111111-1111-4111-8111-111111111111"

  test "startup configuration loads privately and hides credentials", %{tmp_dir: directory} do
    File.chmod!(directory, 0o700)
    path = Path.join(directory, "config.json")

    config = %{
      "version" => 4,
      "control_plane" => "https://example.test",
      "host_id" => @id,
      "credential" => @id <> ":" <> String.duplicate("a", 43),
      "state_dir" => Path.join(directory, "state"),
      "cgroup_path" => "/sys/fs/cgroup/lilly.slice",
      "execution" => execution(),
      "pools" => []
    }

    File.write!(path, JSON.encode!(config))
    File.chmod!(path, 0o600)
    assert {:ok, loaded} = Config.load(path)
    assert loaded.client.host_id == @id
    assert loaded.transfer_bytes_per_second == 67_108_864
    assert loaded.local_transfer_bytes_per_second == 1_073_741_824
    assert loaded.execution.checkpoint_image_ids == []
    qualified_id = "sha256:" <> String.duplicate("a", 64)
    qualified = put_in(config, ["execution", "checkpoint_image_ids"], [qualified_id])
    File.write!(path, JSON.encode!(qualified))
    assert {:ok, qualified_loaded} = Config.load(path)
    assert qualified_loaded.execution.checkpoint_image_ids == [qualified_id]

    for invalid <- [
          nil,
          qualified_id,
          ["linux"],
          [qualified_id, qualified_id],
          Enum.map(1..257, fn n ->
            "sha256:" <> String.pad_leading(Integer.to_string(n, 16), 64, "0")
          end)
        ] do
      File.write!(
        path,
        JSON.encode!(put_in(config, ["execution", "checkpoint_image_ids"], invalid))
      )

      assert {:error, :invalid_runtime_configuration} = Config.load(path)
    end

    for invalid_rate <- [0, -1, 1_073_741_825, "1024", nil] do
      File.write!(
        path,
        JSON.encode!(Map.put(config, "local_transfer_bytes_per_second", invalid_rate))
      )

      assert {:error, :invalid_runtime_configuration} = Config.load(path)
    end

    for invalid_rate <- [0, -1, 1_073_741_825, "1024", nil] do
      File.write!(path, JSON.encode!(Map.put(config, "transfer_bytes_per_second", invalid_rate)))
      assert {:error, :invalid_runtime_configuration} = Config.load(path)
    end

    File.write!(path, JSON.encode!(Map.put(config, "transfer_bytes_per_second", 1_048_576)))
    assert {:ok, %{transfer_bytes_per_second: 1_048_576}} = Config.load(path)
    File.write!(path, JSON.encode!(config))
    assert loaded.transfer_state_dir == nil
    assert loaded.ingress == nil
    assert Lilly.Application.ingress_children(loaded) == []

    ingress = %{"path" => "/run/lilly-ingress/audi.sock", "audi_uid" => 1000}
    enabled = config |> put_in(["execution", "audi_ingress"], true) |> Map.put("ingress", ingress)
    File.write!(path, JSON.encode!(enabled))
    assert {:ok, loaded_ingress} = Config.load(path)
    assert [{Lilly.Ingress.Server, options}] = Lilly.Application.ingress_children(loaded_ingress)
    assert options[:path] == ingress["path"]
    assert options[:audi_uid] == 1000
    assert options[:host_id] == @id

    assert options[:backend] ==
             {Lilly.Ingress.Backend, {Lilly.Control.Runtime, Lilly.Execution.View}}

    private =
      config |> Map.put("ingress", ingress) |> put_in(["execution", "private_services"], true)

    File.write!(path, JSON.encode!(private))
    assert {:ok, private_loaded} = Config.load(path)
    refute private_loaded.execution.network.ingress
    assert private_loaded.execution.network.private_services
    assert [] = Lilly.Application.ingress_children(private_loaded)

    for invalid <- [
          Map.put(config, "ingress", ingress),
          Map.delete(enabled, "ingress"),
          put_in(enabled, ["ingress", "backend"], "Other.Module"),
          put_in(enabled, ["ingress", "path"], "relative.sock"),
          put_in(enabled, ["ingress", "audi_uid"], -1)
        ] do
      File.write!(path, JSON.encode!(invalid))
      assert {:error, :invalid_runtime_configuration} = Config.load(path)
    end

    transfer = Path.join(directory, "transfer-state")
    File.write!(path, JSON.encode!(Map.put(config, "transfer_state_dir", transfer)))
    assert {:ok, %{transfer_state_dir: ^transfer}} = Config.load(path)
    refute File.exists?(transfer)

    for unsafe <- [
          "relative",
          "/",
          "/nix/store/keys",
          config["state_dir"],
          directory,
          config["execution"]["state_dir"] <> "/keys",
          transfer <> "/../keys"
        ] do
      File.write!(path, JSON.encode!(Map.put(config, "transfer_state_dir", unsafe)))
      assert {:error, :invalid_runtime_configuration} = Config.load(path)
    end

    File.write!(path, JSON.encode!(config))
    private? = not String.contains?(inspect(loaded), config["credential"])
    assert private?
    File.chmod!(path, 0o644)
    assert {:error, :invalid_runtime_configuration} = Config.load(path)
    File.chmod!(path, 0o600)
    File.write!(path, "invalid credential contents")
    assert {:error, :invalid_runtime_configuration} = Config.load(path)
  end

  test "a separate private credential file binds host identity and cannot be combined with inline credentials",
       %{tmp_dir: directory} do
    File.chmod!(directory, 0o700)
    credential = Path.join(directory, "credential.json")
    token = @id <> ":" <> String.duplicate("b", 43)

    envelope = %{
      "version" => 1,
      "host_id" => @id,
      "credential_id" => @id,
      "credential" => token,
      "expires_at" => "2030-01-01T00:00:00Z"
    }

    File.write!(credential, JSON.encode!(envelope))
    File.chmod!(credential, 0o600)

    config = %{
      "version" => 4,
      "control_plane" => "https://example.test",
      "host_id" => @id,
      "credential_file" => credential,
      "state_dir" => Path.join(directory, "state"),
      "cgroup_path" => "/sys/fs/cgroup/lilly.slice",
      "execution" => execution(),
      "pools" => []
    }

    path = Path.join(directory, "config.json")
    File.write!(path, JSON.encode!(config))
    File.chmod!(path, 0o600)
    assert {:ok, loaded} = Config.load(path)
    matches? = loaded.client.token == token
    assert matches?
    private? = not String.contains?(inspect(loaded), token)
    assert private?
    File.write!(path, JSON.encode!(Map.put(config, "credential", token)))
    assert {:error, :invalid_runtime_configuration} = Config.load(path)
    File.write!(path, JSON.encode!(config))
    File.chmod!(credential, 0o644)
    assert {:error, :invalid_runtime_configuration} = Config.load(path)
    File.chmod!(credential, 0o600)

    File.write!(
      credential,
      JSON.encode!(Map.put(envelope, "host_id", "22222222-2222-4222-8222-222222222222"))
    )

    assert {:error, :invalid_runtime_configuration} = Config.load(path)
  end

  # @cc [owner:ghuntley,label:verification;capacity] configured-image-shape-tested
  # The images list MUST accept only `{path}` objects, preserve the operator's
  # order and refuse bare paths, the retired `standby` key (ADR-0177), extra
  # keys and duplicate identities.
  test "configured images are path objects kept in order", %{
    tmp_dir: directory
  } do
    File.chmod!(directory, 0o700)
    first = image_directory(Path.join(directory, "first"), "one")
    second = image_directory(Path.join(directory, "second"), "two")
    path = Path.join(directory, "config.json")

    base = %{
      "version" => 4,
      "control_plane" => "https://example.test",
      "host_id" => @id,
      "credential" => @id <> ":" <> String.duplicate("a", 43),
      "state_dir" => Path.join(directory, "state"),
      "cgroup_path" => "/sys/fs/cgroup/lilly.slice",
      "execution" => execution(),
      "pools" => []
    }

    write = fn images ->
      File.write!(path, JSON.encode!(Map.put(base, "images", images)))
      File.chmod!(path, 0o600)
      Config.load(path)
    end

    assert {:ok, loaded} =
             write.([%{"path" => second}, %{"path" => first}])

    assert [%Lilly.Host.Image{} = big, %Lilly.Host.Image{} = small] = loaded.images

    assert big.path == second and small.path == first
    refute big.id == small.id

    for invalid <- [
          [first],
          [%{"path" => first, "standby" => true}],
          [%{"path" => first, "name" => "x"}],
          [%{"path" => first}, %{"path" => first}],
          "not-a-list"
        ] do
      assert {:error, :invalid_runtime_configuration} = write.(invalid)
    end
  end

  defp image_directory(directory, seed) do
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)

    artifacts =
      Map.new(["kernel", "initrd", "rootfs"], fn name ->
        data = "synthetic #{seed} #{name}"
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
    directory
  end

  defp execution do
    tools =
      Map.new(~w(firecracker jailer unshare), fn name ->
        path =
          if name in ["firecracker", "jailer"],
            do: Path.join(System.fetch_env!("OVERALLS_TEST_VMM_DIR"), name),
            else: System.find_executable(name)

        {output, 0} = System.cmd("realpath", [path])
        {name, String.trim(output)}
      end)

    Map.merge(tools, %{
      "state_dir" => "/tmp/lilly-config-test-vms",
      "network_state_dir" => "/tmp/lilly-config-test-network",
      "egress_interface" => "eth0",
      "protected_cidrs" => []
    })
  end
end
