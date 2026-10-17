alias Lilly.Transfer.{Key, PermitJournal, SSH}
root = "/run/transfer-client"
File.mkdir!(root)
File.chmod!(root, 0o700)

request = %{
  host_id: "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb",
  source_host_id: "cccccccc-cccc-4ccc-8ccc-cccccccccccc",
  relocation_id: "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa",
  placement_id: "dddddddd-dddd-4ddd-8ddd-dddddddddddd"
}

[algorithm, encoded | _] = File.read!("/etc/ssh/ssh_host_ed25519_key.pub") |> String.split()
endpoint = %{"address" => "127.0.0.1", "port" => 2222, "host_key" => algorithm <> " " <> encoded}
{:ok, public} = Key.ensure(root, request.host_id, request.relocation_id, request.placement_id)

permit_root = "/run/source-permits"
File.mkdir!(permit_root)
File.chmod!(permit_root, 0o700)

wire = %{
  "version" => 3,
  "relocation_id" => request.relocation_id,
  "vm_id" => "ffffffff-ffff-4fff-8fff-ffffffffffff",
  "source" => %{
    "host_id" => request.source_host_id,
    "pool_id" => "11111111-1111-4111-8111-111111111111",
    "placement_id" => "22222222-2222-4222-8222-222222222222"
  },
  "destination" => %{
    "host_id" => request.host_id,
    "pool_id" => "33333333-3333-4333-8333-333333333333",
    "placement_id" => request.placement_id
  },
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
  "stream" => %{
    "source_dataset_guid" => "100",
    "to_guid" => "200"
  }
}

now = System.system_time(:second)
:ok = PermitJournal.grant(permit_root, wire, public, 1, now + 300, now)

# hostd accepts only typed consumers; `compare` succeeds only when the pulled
# stream equals the expected 32 MiB byte for byte.
File.write!("/run/transfer-expected", :binary.copy(<<0>>, 33_554_432))
consumer = {:compare, "/run/transfer-expected"}
# A refused source sends nothing: against an empty expectation only the SSH
# producer can fail, so the refusal reason is deterministic.
refused = {:compare, "/dev/null"}

:ok = SSH.pull(root, request, endpoint, consumer, 60_000)

true = File.exists?("/tmp/transfer-export-ran")
"ssh-ed25519 " <> authenticated = public
^authenticated = File.read!("/tmp/authenticated-export-key")
File.rm!("/tmp/transfer-export-ran")

# A stream that differs in its last byte is not accepted. The consumer's exit
# races the producer's closing pipe, so either stream failure is reported.
File.write!("/run/transfer-other", :binary.copy(<<0>>, 33_554_431) <> <<1>>)

{:error, mismatch} =
  SSH.pull(root, request, endpoint, {:compare, "/run/transfer-other"}, 60_000)

true = mismatch in [:stream_consumer_failed, :stream_pipe_failed, :stream_children_failed]

File.rm!("/tmp/transfer-export-ran")

# A valid but different host key cannot authenticate even when the user key is accepted.
other = %{request | relocation_id: "eeeeeeee-eeee-4eee-8eee-eeeeeeeeeeee"}
{:ok, other_public} = Key.ensure(root, other.host_id, other.relocation_id, other.placement_id)

{:error, :stream_producer_failed} =
  SSH.pull(root, other, %{endpoint | "host_key" => other_public}, refused, 15_000)

false = File.exists?("/tmp/transfer-export-ran")

# The other valid client key has no source permit and cannot authorize an export.
ungranted = %{request | relocation_id: "44444444-4444-4444-8444-444444444444"}
{:ok, _} = Key.ensure(root, ungranted.host_id, ungranted.relocation_id, ungranted.placement_id)
{:error, :stream_producer_failed} = SSH.pull(root, ungranted, endpoint, refused, 60_000)
false = File.exists?("/tmp/transfer-export-ran")
:ok = SSH.pull(root, request, endpoint, consumer, 60_000)
File.rm!("/tmp/transfer-export-ran")
:ok = PermitJournal.fence(permit_root, request.source_host_id, request.relocation_id)
{:error, :stream_producer_failed} = SSH.pull(root, request, endpoint, refused, 60_000)
false = File.exists?("/tmp/transfer-export-ran")
:ok = Key.retire(root, request.host_id, request.relocation_id, request.placement_id)
# A retired key refuses the connection before any SSH process starts.
{:error, :invalid_transfer_connection} = SSH.pull(root, request, endpoint, refused, 15_000)

IO.puts(
  "Pinned SSH transfer, authenticated key delivery, permit revocation and retired-key checks passed"
)
