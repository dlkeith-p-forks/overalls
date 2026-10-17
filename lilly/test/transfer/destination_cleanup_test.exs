defmodule Lilly.Transfer.DestinationCleanupTest do
  use ExUnit.Case, async: true
  import ExUnit.CaptureLog
  alias Lilly.Host.Pool
  alias Lilly.Transfer.{DestinationCleanup, Key}
  @moduletag :tmp_dir
  defp uuid(n), do: "00000000-0000-0000-0000-" <> String.pad_leading("#{n}", 12, "0")

  setup %{tmp_dir: dir} do
    File.chmod!(dir, 0o700)

    pool = %Pool{
      id: uuid(8),
      host_id: uuid(7),
      path: Path.join(dir, "pool"),
      filesystem_id: "zfs:500:600",
      storage: %{backend: :zfs, zpool_guid: "500", dataset_guid: "600", dataset: "target/lilly"}
    }

    intent = %{
      relocation_id: uuid(1),
      vm_id: uuid(2),
      source: %{placement_id: uuid(3), host_id: uuid(4), pool_id: uuid(5)},
      destination: %{placement_id: uuid(6), host_id: pool.host_id, pool_id: pool.id},
      source_epoch: 1,
      destination_epoch: 2,
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

    config = %Lilly.Control.Config{
      state_dir: dir,
      cgroup_path: "/sys/fs/cgroup/lilly.slice",
      client: %Lilly.Control.Client{
        host_id: pool.host_id,
        base_url: "https://fixture.invalid",
        token: "unused"
      },
      pools: [pool],
      transfer_state_dir: Path.join(dir, "transfer"),
      execution: %{state_dir: Path.join(dir, "execution")}
    }

    %{config: config, intent: intent, wire: OverallsProtocol.Relocation.encode_intent(intent)}
  end

  test "invalid authority and leases have no key or execution effects", c do
    now = System.system_time(:second)

    for {wire, expires, config} <- [
          {nil, now + 180, c.config},
          {Map.put(c.wire, "stream", %{}), now + 180, c.config},
          {put_in(c.wire, ["destination", "placement_id"], "../other"), now + 180, c.config},
          {c.wire, now, c.config},
          {c.wire, now + 301, c.config},
          {c.wire, nil, c.config},
          {c.wire, now + 180, %{c.config | pools: []}},
          {c.wire, now + 180, %{c.config | client: %{c.config.client | host_id: uuid(99)}}}
        ] do
      assert {:error, :destination_cleanup_unconfirmed} =
               DestinationCleanup.execute(config, wire, expires)

      refute File.exists?(c.config.transfer_state_dir)
      refute File.exists?(c.config.execution.state_dir)
    end
  end

  test "unavailable privileged execution retains the key fence without claiming reclamation", c do
    :ok = Lilly.Host.PrivateFiles.directory(c.config.transfer_state_dir)

    for _ <- 1..2 do
      assert {:error, :destination_cleanup_unconfirmed} =
               DestinationCleanup.execute(c.config, c.wire, System.system_time(:second) + 180)

      assert {:error, :transfer_key_retired} =
               Key.ensure(
                 c.config.transfer_state_dir,
                 c.intent.destination.host_id,
                 c.intent.relocation_id,
                 c.intent.destination.placement_id
               )

      refute File.exists?(c.config.execution.state_dir)
      refute File.exists?(hd(c.config.pools).path)
    end
  end

  test "confirmed rejections emit correlated cleanup diagnostics without intent payloads", c do
    output =
      capture_log([metadata: [:event, :reason, :relocation_id, :placement_id]], fn ->
        assert {:error, :destination_cleanup_unconfirmed} =
                 DestinationCleanup.execute(c.config, c.wire, System.system_time(:second))
      end)

    assert output =~ "lilly.cleanup_unconfirmed"
    assert output =~ "destination_cleanup_unconfirmed"
    assert output =~ c.intent.relocation_id
    assert output =~ c.intent.destination.placement_id
    refute output =~ c.intent.workload.image_id
  end
end
