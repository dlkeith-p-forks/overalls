defmodule Lilly.Transfer.ProbeTest do
  use ExUnit.Case, async: true
  alias Lilly.Control.{Client, Config, Store}
  alias Lilly.Transfer.Probe
  @moduletag :tmp_dir
  defp id(n), do: "00000000-0000-4000-8000-" <> String.pad_leading(to_string(n), 12, "0")

  defp command do
    %{
      id: id(1),
      generation: 1,
      phase: :grant,
      challenge: id(10),
      source_endpoint: nil,
      revision: 1,
      expires_at: 1_900_000_000,
      public_key: "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 0::256>>),
      intent: %{
        relocation_id: id(2),
        vm_id: id(3),
        source_epoch: 1,
        destination_epoch: 2,
        source: %{placement_id: id(4), host_id: id(5), pool_id: id(6)},
        destination: %{placement_id: id(7), host_id: id(8), pool_id: id(9)},
        workload: %{
          image_id: "sha256:" <> String.duplicate("a", 64),
          architecture: :x86_64,
          profile: :customer,
          slot: 2,
          vcpu: 1,
          memory_bytes: 536_870_912,
          disk_bytes: 2_147_483_648
        }
      }
    }
  end

  test "stale authority, invalid leases and absent source state never install grants", c do
    request = %{command() | expires_at: System.system_time(:second) + 180}
    host = request.intent.source.host_id
    {:ok, store} = Store.open(Path.join(c.tmp_dir, "control"), host)
    root = Path.join(c.tmp_dir, "transfer")

    config = %Config{
      client: %Client{host_id: host, base_url: "https://fixture.invalid", token: "unused"},
      state_dir: c.tmp_dir,
      cgroup_path: "/sys/fs/cgroup/lilly.slice",
      pools: [],
      transfer_state_dir: root
    }

    for bad <- [
          request,
          %{request | expires_at: System.system_time(:second)},
          %{request | expires_at: System.system_time(:second) + 301}
        ] do
      assert {:error, :probe_unconfirmed} = Probe.execute(config, store, bad)
      refute File.exists?(root)
    end

    execution =
      request.intent.workload
      |> Map.merge(%{
        id: id(30),
        vm_id: request.intent.vm_id,
        owner_id: "0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f",
        placement_id: request.intent.source.placement_id,
        host_id: host,
        pool_id: request.intent.source.pool_id,
        execution_epoch: request.intent.source_epoch,
        generation: 2,
        kind: :start
      })

    assert {:ok, :stored} = Store.accept(store, execution)
    assert {:error, :probe_unconfirmed} = Probe.execute(config, store, request)

    for kind <- [:stop, :delete] do
      execution = %{
        execution
        | id: id(if(kind == :stop, do: 31, else: 32)),
          generation: if(kind == :stop, do: 3, else: 4),
          kind: kind
      }

      assert {:ok, :stored} = Store.accept(store, execution)

      assert {:error, :probe_unconfirmed} =
               Probe.execute(config, store, %{request | generation: execution.generation})

      assert {:ok, ^execution} = Store.read(store, execution.placement_id)
      refute File.exists?(root)
    end
  end

  test "destination refuses a command naming a different local public key", c do
    request = %{
      command()
      | phase: :probe,
        expires_at: System.system_time(:second) + 180,
        source_endpoint: %{
          "address" => "source.example",
          "port" => 2222,
          "host_key" => command().public_key
        }
    }

    host = request.intent.destination.host_id
    {:ok, store} = Store.open(Path.join(c.tmp_dir, "control"), host)
    root = Path.join(c.tmp_dir, "transfer")
    :ok = Lilly.Host.PrivateFiles.directory(root)

    {:ok, public} =
      Lilly.Transfer.Key.ensure(
        root,
        host,
        request.intent.relocation_id,
        request.intent.destination.placement_id
      )

    refute public == request.public_key

    config = %Config{
      client: %Client{host_id: host, base_url: "https://fixture.invalid", token: "unused"},
      state_dir: c.tmp_dir,
      cgroup_path: "/sys/fs/cgroup/lilly.slice",
      pools: [],
      transfer_state_dir: root
    }

    assert {:error, :probe_unconfirmed} = Probe.execute(config, store, request)

    refute File.exists?(
             Path.join([
               root,
               "transfers",
               request.intent.relocation_id,
               "probe-" <> request.challenge
             ])
           )

    assert :ok =
             Lilly.Transfer.Key.retire(
               root,
               host,
               request.intent.relocation_id,
               request.intent.destination.placement_id
             )

    assert {:error, :probe_unconfirmed} =
             Probe.execute(config, store, %{request | public_key: public})
  end

  test "probe role cannot execute on the source or an unrelated host", c do
    request = %{
      command()
      | phase: :probe,
        expires_at: System.system_time(:second) + 180,
        source_endpoint: %{
          "address" => "source.example",
          "port" => 2222,
          "host_key" => command().public_key
        }
    }

    for host <- [request.intent.source.host_id, id(99)] do
      root = Path.join(c.tmp_dir, host)
      :ok = Lilly.Host.PrivateFiles.directory(root)
      {:ok, store} = Store.open(Path.join(root, "control"), host)

      config = %Config{
        client: %Client{host_id: host, base_url: "https://fixture.invalid", token: "unused"},
        state_dir: root,
        cgroup_path: "/sys/fs/cgroup/lilly.slice",
        pools: [],
        transfer_state_dir: Path.join(root, "transfer")
      }

      assert {:error, :probe_unconfirmed} = Probe.execute(config, store, request)
      refute File.exists?(config.transfer_state_dir)
    end
  end
end
