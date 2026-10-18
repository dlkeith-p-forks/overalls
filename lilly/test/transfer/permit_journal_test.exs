defmodule Lilly.Transfer.PermitJournalTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Transfer.PermitJournal, as: Journal
  @moduletag :tmp_dir
  defp uuid(n), do: "00000000-0000-0000-0000-" <> String.pad_leading(to_string(n), 12, "0")
  defp key(n), do: "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, n::256>>)

  setup %{tmp_dir: root} do
    File.chmod!(root, 0o700)

    wire = %{
      "version" => 3,
      "relocation_id" => uuid(1),
      "vm_id" => uuid(2),
      "source" => %{"placement_id" => uuid(3), "host_id" => uuid(4), "pool_id" => uuid(5)},
      "destination" => %{"placement_id" => uuid(6), "host_id" => uuid(7), "pool_id" => uuid(8)},
      "source_epoch" => 1,
      "destination_epoch" => 2,
      "workload" => %{
        "image_id" => "sha256:" <> String.duplicate("a", 64),
        "architecture" => "x86_64",
        "profile" => "customer",
        "slot" => 2,
        "vcpu" => 1,
        "memory_bytes" => 536_870_912,
        "disk_bytes" => 2_147_483_648
      },
      "stream" => %{"source_dataset_guid" => "100", "to_guid" => "200"}
    }

    %{root: root, wire: wire, public: key(1), host: uuid(4), relocation: uuid(1)}
  end

  defp grant(c, revision \\ 1, expires \\ 1200, now \\ 1000),
    do: Journal.grant(c.root, c.wire, c.public, revision, expires, now)

  defp lookup(c, now \\ 1000),
    do: Journal.lookup(c.root, c.host, c.relocation, c.public, now)

  defp path(c), do: Path.join([c.root, "exports", c.relocation, "permit.json"])

  defp key_path(c) do
    name = :crypto.hash(:sha256, c.public) |> Base.encode16(case: :lower)
    Path.join([c.root, "exports", "keys", name <> ".json"])
  end

  defp probe(c, revision \\ 1, expires \\ 1200, now \\ 1000) do
    Journal.probe(
      c.root,
      Map.delete(c.wire, "stream"),
      c.public,
      uuid(90),
      revision,
      expires,
      now
    )
  end

  test "authenticated disk export never grants RAM without its exact descriptor", c do
    alias Lilly.Transfer.ExportRequest
    assert :ok = grant(c)
    disk = "lilly-export-v4 #{c.relocation}"
    memory = "lilly-checkpoint-v1 #{c.relocation}"
    assert {:ok, _} = ExportRequest.lookup(c.root, c.host, c.public, disk, 1000)
    assert {:error, _} = ExportRequest.lookup(c.root, c.host, c.public, memory, 1000)

    checkpoint = %{
      "id" => uuid(20),
      "memory_bytes" => 536_870_912,
      "state_bytes" => 4096,
      "compatibility" => "sha256:" <> String.duplicate("a", 64),
      "memory_sha256" => "sha256:" <> String.duplicate("b", 64),
      "state_sha256" => "sha256:" <> String.duplicate("c", 64),
      "manifest_sha256" => "sha256:" <> String.duplicate("d", 64),
      "dataset_guid" => "300",
      "snapshot_guid" => "400"
    }

    separate = Path.join(c.root, "memory-permit")
    File.mkdir!(separate)
    File.chmod!(separate, 0o700)
    with_ram = %{c | root: separate, wire: Map.put(c.wire, "checkpoint", checkpoint)}
    assert :ok = grant(with_ram)

    assert {:ok, %{descriptor: %{checkpoint: %{snapshot_guid: "400"}}}} =
             ExportRequest.lookup(with_ram.root, c.host, c.public, memory, 1000)

    assert {:error, _} = ExportRequest.lookup(with_ram.root, c.host, key(2), memory, 1000)
    assert {:error, _} = ExportRequest.lookup(with_ram.root, c.host, c.public, memory, 1200)
    assert :ok = Journal.fence(with_ram.root, c.host, c.relocation)
    assert {:error, _} = ExportRequest.lookup(with_ram.root, c.host, c.public, memory, 1000)
  end

  test "restricted endpoint authenticates probes and emits only the current challenge", c do
    alias Lilly.Transfer.{Endpoint, ExportRequest, ProbeRequest}
    assert :ok = probe(c, 1, System.system_time(:second) + 120, System.system_time(:second))
    now = System.system_time(:second)
    assert {:ok, %{pool_id: pool}} = Journal.authentication(c.root, c.host, c.public, now)
    assert pool == c.wire["source"]["pool_id"]

    config = %{
      "version" => 3,
      "host_id" => c.host,
      "root" => c.root,
      "pools" => [
        %{
          "id" => pool,
          "path" => c.root <> "-pool",
          "filesystem_id" => "zfs:1:2",
          "storage" => %{
            "backend" => "zfs",
            "zpool_guid" => "1",
            "dataset_guid" => "2",
            "dataset" => "tank/lilly"
          }
        }
      ]
    }

    path = Path.join(c.root, "endpoint.json")
    File.write!(path, JSON.encode!(config))
    File.chmod!(path, 0o600)
    "ssh-ed25519 " <> encoded = c.public

    assert {:ok, line} =
             Endpoint.authorize(path, "lilly-transfer", "ssh-ed25519", encoded, "/bin/export")

    assert line == "restrict,command=\"/bin/export #{encoded}\" #{c.public}\n"
    command = "lilly-probe-v3 #{c.relocation} #{uuid(90)}"
    assert {:ok, _} = ProbeRequest.parse(command)
    assert {:error, _} = ExportRequest.parse(command)

    assert ExUnit.CaptureIO.capture_io(fn ->
             assert :ok = Endpoint.run(path, encoded, command)
           end) ==
             "lilly-probe-v3 #{uuid(90)}\n"

    for bad <- [
          command <> "\n",
          command <> ";id",
          command <> " extra",
          String.replace(command, " ", "\t"),
          "lilly-probe-v3 #{c.relocation} #{uuid(91)}"
        ] do
      assert ExUnit.CaptureIO.capture_io(fn ->
               assert {:error, _} = Endpoint.run(path, encoded, bad)
             end) == ""
    end

    assert {:error, _} = Endpoint.run(path, encoded, "lilly-export-v4 #{c.relocation}")
    File.rm!(key_path(c))

    assert {:error, _} =
             Endpoint.authorize(path, "lilly-transfer", "ssh-ed25519", encoded, "/bin/export")

    assert :ok = Journal.fence(c.root, c.host, c.relocation)

    assert ExUnit.CaptureIO.capture_io(fn ->
             assert {:error, _} = Endpoint.run(path, encoded, command)
           end) == ""

    refute File.exists?(c.root <> "-pool")
  end

  test "probe leases grant no snapshot export and retain permanent revocation", c do
    assert :ok = probe(c)
    assert :ok = Journal.prepare(c.root, c.host, c.relocation)

    assert {:ok, %{revision: 1}} =
             Journal.lookup_probe(c.root, c.host, c.relocation, c.public, uuid(90), 1000)

    assert {:error, _} = Journal.for_key(c.root, c.host, c.public, 1000)
    assert {:error, _} = lookup(c)

    for {host, relocation, public, challenge, now} <- [
          {uuid(99), c.relocation, c.public, uuid(90), 1000},
          {c.host, uuid(99), c.public, uuid(90), 1000},
          {c.host, c.relocation, key(2), uuid(90), 1000},
          {c.host, c.relocation, c.public, uuid(91), 1000},
          {c.host, c.relocation, c.public, uuid(90), 999},
          {c.host, c.relocation, c.public, uuid(90), 1200}
        ] do
      assert {:error, _} = Journal.lookup_probe(c.root, host, relocation, public, challenge, now)
    end

    assert :ok = Journal.fence(c.root, c.host, c.relocation)
    assert {:error, _} = probe(c, 2, 1300, 1100)
    assert {:error, _} = grant(c)

    assert {:error, _} =
             Journal.lookup_probe(c.root, c.host, c.relocation, c.public, uuid(90), 1000)
  end

  test "probe renewal preserves identity, revision and durable key ownership", c do
    assert :ok = probe(c)
    before = File.read!(path(c))
    assert :ok = probe(c, 1, 1200, 1001)
    assert before == File.read!(path(c))
    assert {:error, _} = probe(c, 1, 1250, 1001)
    assert {:error, _} = probe(c, 2, 1199, 1001)
    assert {:error, _} = probe(c, 2, 1401, 1100)
    assert {:error, _} = probe(%{c | public: key(2)}, 2, 1300, 1100)
    assert {:error, _} = probe(%{c | wire: Map.put(c.wire, "vm_id", uuid(99))}, 2, 1300, 1100)
    assert {:error, _} = probe(%{c | wire: Map.put(c.wire, "relocation_id", uuid(99))})
    assert :ok = probe(c, 2, 1300, 1100)
    File.rm!(key_path(c))
    assert {:error, _} = probe(c, 3, 1400, 1200)
    refute File.exists?(key_path(c))
    assert :ok = Journal.fence(c.root, c.host, c.relocation)
  end

  test "only the same full-copy intent can replace a probe grant", c do
    assert :ok = probe(c)
    assert {:error, _} = lookup(c)
    assert {:error, _} = grant(%{c | public: key(2)})
    assert {:error, _} = grant(%{c | wire: Map.put(c.wire, "vm_id", uuid(99))})
    assert :ok = grant(c)
    assert {:ok, _} = lookup(c)
    assert {:error, _} = probe(c, 2, 1300, 1100)

    assert {:error, _} =
             Journal.lookup_probe(c.root, c.host, c.relocation, c.public, uuid(90), 1000)
  end

  test "preparation creates no grant and cannot repair or revive retained state", c do
    assert :ok = Journal.prepare(c.root, c.host, c.relocation)
    assert :ok = Journal.prepare(c.root, c.host, c.relocation)
    assert {:error, _} = lookup(c)
    assert :ok = grant(c)
    assert {:ok, before} = lookup(c)
    assert :ok = Journal.prepare(c.root, c.host, c.relocation)
    assert {:ok, ^before} = lookup(c)
    assert :ok = Journal.fence(c.root, c.host, c.relocation)
    assert {:error, _} = Journal.prepare(c.root, c.host, c.relocation)
    assert {:error, _} = lookup(c)
    File.rm!(path(c))
    assert {:error, _} = Journal.prepare(c.root, c.host, c.relocation)
    refute File.exists?(path(c))
  end

  test "SSH request lookup binds authenticated peer, local host and exact phase", c do
    alias Lilly.Transfer.ExportRequest
    command = "lilly-export-v4 #{c.relocation}"
    assert {:error, _} = ExportRequest.lookup(c.root, c.host, c.public, command, 1000)
    assert :ok = grant(c)

    assert {:ok, %{revision: 1}} =
             ExportRequest.lookup(c.root, c.host, c.public, command, 1000)

    for {host, public, request, now} <- [
          {uuid(99), c.public, command, 1000},
          {c.host, key(2), command, 1000},
          {c.host, c.public, "lilly-export-v4 #{uuid(99)}", 1000},
          {c.host, c.public, "lilly-export-v3 #{c.relocation} full", 1000},
          {c.host, c.public, command <> "\n", 1000},
          {c.host, c.public, command, 1200}
        ] do
      assert {:error, :export_permit_unconfirmed} =
               ExportRequest.lookup(c.root, host, public, request, now)
    end

    assert :ok = Journal.fence(c.root, c.host, c.relocation)

    assert {:error, :export_permit_unconfirmed} =
             ExportRequest.lookup(c.root, c.host, c.public, command, 1000)
  end

  test "SSH key lookup follows current lineage and rejects absent, wrong or expired authority",
       c do
    assert {:error, _} = Journal.for_key(c.root, c.host, c.public, 1000)
    refute File.exists?(Path.join(c.root, "exports"))
    assert :ok = grant(c)

    assert {:ok, %{descriptor: %{stream: %{to_guid: "200"}}, revision: 1}} =
             Journal.for_key(c.root, c.host, c.public, 1000)

    for {host, public, now} <- [
          {uuid(99), c.public, 1000},
          {c.host, key(2), 1000},
          {c.host, c.public, 999},
          {c.host, c.public, 1200},
          {c.host, "not a key", 1000}
        ] do
      assert {:error, :export_permit_unconfirmed} = Journal.for_key(c.root, host, public, now)
    end

    assert :ok = grant(c, 2)

    assert {:ok, %{descriptor: %{stream: %{to_guid: "200"}}, revision: 2}} =
             Journal.for_key(c.root, c.host, c.public, 1000)

    assert :ok = Journal.fence(c.root, c.host, c.relocation)
    assert {:error, _} = Journal.for_key(c.root, c.host, c.public, 1000)
  end

  test "OpenSSH authorization binds the forced command to the offered active key", c do
    alias Lilly.Transfer.ExportRequest
    executable = "/nix/store/fixture/bin/lilly-export-request"
    assert {:error, _} = ExportRequest.authorized_key(c.root, c.host, c.public, executable, 1000)
    assert :ok = grant(c)
    "ssh-ed25519 " <> encoded = c.public
    assert {:ok, line} = ExportRequest.authorized_key(c.root, c.host, c.public, executable, 1000)
    assert line == "restrict,command=\"#{executable} #{encoded}\" #{c.public}\n"

    for bad <- ["relative", "/bin/export;evil", "/bin/$PATH", "/bin/export\"", "/bin/../export"] do
      assert {:error, _} = ExportRequest.authorized_key(c.root, c.host, c.public, bad, 1000)
    end

    assert {:error, _} = ExportRequest.authorized_key(c.root, c.host, key(2), executable, 1000)
    assert {:error, _} = ExportRequest.authorized_key(c.root, c.host, c.public, executable, 1200)
    assert :ok = Journal.fence(c.root, c.host, c.relocation)
    assert {:error, _} = ExportRequest.authorized_key(c.root, c.host, c.public, executable, 1000)
  end

  test "one public key cannot authorize a different relocation even after retirement", c do
    assert :ok = grant(c)
    original = File.read!(key_path(c))
    other = %{c | relocation: uuid(99), wire: Map.put(c.wire, "relocation_id", uuid(99))}
    assert {:error, _} = grant(other)
    assert {:error, _} = lookup(other)
    assert File.read!(key_path(c)) == original
    assert :ok = Journal.fence(c.root, c.host, c.relocation)
    assert {:error, _} = grant(other)
    assert File.read!(key_path(c)) == original
    assert :ok = grant(%{other | public: key(2)})
  end

  defp revoke_command(c),
    do: %{
      id: c.relocation,
      host_id: c.host,
      placement_id: c.wire["source"]["placement_id"],
      execution_epoch: c.wire["source_epoch"],
      expires_at: System.system_time(:second) + 180
    }

  test "source revocation rejects invalid host, lease and paths without local effects", c do
    command = revoke_command(c)

    for invalid <- [
          %{command | host_id: uuid(9)},
          %{command | expires_at: System.system_time(:second)},
          %{command | expires_at: System.system_time(:second) + 600},
          Map.put(command, :path, "/tmp/foreign")
        ] do
      assert {:error, :source_revocation_unconfirmed} =
               Lilly.Transfer.SourceRevocation.execute(c.root, c.host, invalid)

      assert File.ls!(c.root) == []
    end

    assert {:ok, receipt} = Lilly.Transfer.SourceRevocation.execute(c.root, c.host, command)
    assert receipt == Map.take(command, [:id, :placement_id, :execution_epoch])
    assert {:ok, ^receipt} = Lilly.Transfer.SourceRevocation.execute(c.root, c.host, command)
    assert {:error, _} = grant(c)
  end

  test "revocation persists immediately but cannot acknowledge a held sender lock", c do
    assert :ok = grant(c)
    directory = Path.join([c.root, "exports", c.relocation, "stream"])
    parent = self()

    task =
      Task.async(fn ->
        {:ok, lock} = Lilly.Host.Lock.acquire(directory)
        send(parent, {:sender_registered, self()})

        receive do
          :release -> Lilly.Host.Lock.release(lock)
        end
      end)

    try do
      assert_receive {:sender_registered, sender}, 3000

      assert {:error, :source_revocation_unconfirmed} =
               Lilly.Transfer.SourceRevocation.execute(c.root, c.host, revoke_command(c))

      assert {:error, _} = Journal.for_key(c.root, c.host, c.public, 1000)
      assert {:error, _} = grant(c, 2)
      send(sender, :release)
      assert :ok = Task.await(task)

      assert {:ok, receipt} =
               Lilly.Transfer.SourceRevocation.execute(c.root, c.host, revoke_command(c))

      assert {:ok, ^receipt} =
               Lilly.Transfer.SourceRevocation.execute(c.root, c.host, revoke_command(c))
    after
      send(task.pid, :release)
      Task.shutdown(task, 5000)
    end
  end

  test "revocation rejects substituted stream paths but confirms a never-started transfer", c do
    assert :ok = grant(c)
    stream = Path.join([c.root, "exports", c.relocation, "stream"])
    File.ln_s!(c.root, stream)

    assert {:error, :export_revocation_unconfirmed} =
             Lilly.Transfer.SourceExport.revoke(c.root, c.host, c.relocation)

    assert {:error, _} = lookup(c)
    File.rm!(stream)
    assert :ok = Lilly.Transfer.SourceExport.revoke(c.root, c.host, c.relocation)
    refute File.exists?(stream)
  end

  test "missing or corrupt key index cannot be repaired by renewal and never prevents fencing",
       c do
    assert :ok = grant(c)
    original = File.read!(key_path(c))
    File.rm!(key_path(c))
    assert {:error, _} = Journal.for_key(c.root, c.host, c.public, 1000)
    assert {:error, _} = grant(c, 2)
    refute File.exists?(key_path(c))
    File.write!(key_path(c), "corrupt")
    File.chmod!(key_path(c), 0o600)
    assert {:error, _} = Journal.for_key(c.root, c.host, c.public, 1000)
    assert {:error, _} = grant(c, 2)
    assert File.read!(key_path(c)) == "corrupt"
    assert :ok = Journal.fence(c.root, c.host, c.relocation)
    File.write!(key_path(c), original)
    assert {:error, _} = Journal.for_key(c.root, c.host, c.public, 1000)
    assert {:error, _} = grant(c, 3)
  end

  test "a key binding published before an interrupted grant only permits the original retry", c do
    assert :ok = Journal.prepare(c.root, c.host, c.relocation)
    before_grant = File.read!(path(c))
    assert :ok = grant(c)
    # Crash after the key index publishes but before the permit publication.
    File.write!(path(c), before_grant)
    assert {:error, _} = Journal.for_key(c.root, c.host, c.public, 1000)
    other = %{c | relocation: uuid(99), wire: Map.put(c.wire, "relocation_id", uuid(99))}
    assert {:error, _} = grant(other)
    assert :ok = grant(c)
    assert {:ok, %{revision: 1}} = Journal.for_key(c.root, c.host, c.public, 1000)
  end

  test "key lookup rejects substituted identity and unsafe index files", c do
    assert :ok = grant(c)
    original = File.read!(key_path(c))
    binding = JSON.decode!(original)

    for changed <- [
          Map.put(binding, "host_id", uuid(99)),
          Map.put(binding, "public_key", key(2)),
          Map.put(binding, "relocation_id", uuid(99)),
          Map.put(binding, "extra", true)
        ] do
      File.write!(key_path(c), JSON.encode!(changed))
      assert {:error, _} = Journal.for_key(c.root, c.host, c.public, 1000)
    end

    File.write!(key_path(c), original)
    File.chmod!(key_path(c), 0o644)
    assert {:error, _} = Journal.for_key(c.root, c.host, c.public, 1000)
    File.chmod!(key_path(c), 0o600)
    outside = Path.join(c.root, "index-copy")
    File.rename!(key_path(c), outside)
    File.ln_s!(outside, key_path(c))
    assert {:error, _} = Journal.for_key(c.root, c.host, c.public, 1000)
    assert {:error, _} = grant(c, 2)
    assert File.read!(outside) == original
    assert :ok = Journal.fence(c.root, c.host, c.relocation)
  end

  test "exact retries preserve issuance time; expiry and backward clocks fail closed", c do
    assert {:error, _} = lookup(c)
    assert :ok = grant(c)
    original = File.read!(path(c))
    assert :ok = grant(c, 1, 1200, 1100)
    assert File.read!(path(c)) == original
    assert {:ok, %{revision: 1, expires_at: 1200}} = lookup(c, 1199)
    assert {:error, _} = lookup(c, 1200)
    assert {:error, _} = lookup(c, 999)
    assert :ok = grant(c, 2, 1450, 1201)
    assert {:ok, %{revision: 2}} = lookup(c, 1201)
    assert {:error, _} = grant(c, 1, 1450, 1201)
    assert {:error, _} = grant(c, 2, 1451, 1201)
    assert {:error, _} = grant(c, 3, 1449, 1201)
  end

  test "peer and immutable descriptor cannot change; renewal keeps the exact stream", c do
    for legacy <- [
          put_in(c.wire, ["stream", "kind"], "full"),
          put_in(c.wire, ["stream", "from_guid"], nil)
        ] do
      assert {:error, _} = grant(%{c | wire: legacy})
      refute File.exists?(path(c))
    end

    assert :ok = grant(c)

    for changed <- [
          %{c | public: key(2)},
          %{c | wire: Map.put(c.wire, "vm_id", uuid(99))},
          %{c | wire: put_in(c.wire, ["destination", "host_id"], uuid(99))},
          %{c | wire: put_in(c.wire, ["stream", "to_guid"], "201")},
          %{c | wire: put_in(c.wire, ["stream", "source_dataset_guid"], "101")}
        ] do
      assert {:error, _} = grant(changed, 2)
    end

    assert :ok = grant(c, 2)
    assert {:ok, %{revision: 2, descriptor: %{stream: %{to_guid: "200"}}}} = lookup(c)
    assert {:error, _} = grant(c, 1)
    assert {:error, _} = lookup(%{c | public: key(2)})
  end

  test "revocation before or after issuance is permanent and retains history", c do
    assert :ok = Journal.fence(c.root, c.host, c.relocation)
    assert {:error, _} = grant(c)
    assert :ok = Journal.fence(c.root, c.host, c.relocation)
    assert {:error, _} = lookup(c)
    other = %{c | relocation: uuid(99), wire: Map.put(c.wire, "relocation_id", uuid(99))}
    assert :ok = grant(other)
    before = File.read!(path(other)) |> JSON.decode!()
    assert :ok = Journal.fence(other.root, other.host, other.relocation)
    after_fence = File.read!(path(other)) |> JSON.decode!()
    assert after_fence["grant"] == before["grant"]
    assert {:error, _} = grant(other, 99, 1300)
    assert {:error, _} = lookup(other)
  end

  test "missing or corrupt published state is not recreated and symlinks are refused", c do
    assert :ok = grant(c)
    original = File.read!(path(c))
    File.rm!(path(c))
    assert {:error, _} = grant(c)
    assert {:error, _} = Journal.fence(c.root, c.host, c.relocation)
    refute File.exists?(path(c))
    File.write!(path(c), "corrupt")
    File.chmod!(path(c), 0o600)
    assert {:error, _} = lookup(c)
    assert {:error, _} = grant(c)
    File.rm!(path(c))
    external = Path.join(c.root, "external")
    File.write!(external, original)
    File.chmod!(external, 0o600)
    File.ln_s!(external, path(c))
    assert {:error, _} = lookup(c)
    assert {:error, _} = Journal.fence(c.root, c.host, c.relocation)
    assert File.read!(external) == original
  end

  test "permits cannot switch stream, host binding or invalid revisions", c do
    for revision <- [0, -1, 9_223_372_036_854_775_808, "1"] do
      assert {:error, _} = grant(c, revision)
      refute File.exists?(path(c))
    end

    assert :ok = grant(c)
    assert {:ok, _} = lookup(c)
    assert {:error, _} = grant(%{c | wire: put_in(c.wire, ["stream", "to_guid"], "300")}, 2)
    assert {:error, _} = Journal.fence(c.root, uuid(99), c.relocation)
    assert {:ok, _} = lookup(c)

    assert Enum.sort(File.ls!(Path.join(c.root, "exports"))) ==
             Enum.sort(["owner.lock", "keys", c.relocation])
  end

  test "leases reject zero, negative and excessive validity before persistence", c do
    Hegel.check(
      fn ->
        offset = draw("offset", one_of([integer(-1000..0), integer(301..10000)]))
        assert {:error, _} = grant(c, 1, 1000 + offset)
        refute File.exists?(path(c))
      end,
      []
    )
  end
end
