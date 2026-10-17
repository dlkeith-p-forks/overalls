# @cc [owner:ghuntley,label:verification] native-export-uses-production-custody
# This isolated entry point MUST invoke SourceExport with a real locally owned
# pool and durable permit. Stdout MUST contain only the native ZFS stream; failures
# return a nonzero exit without printing descriptors or utility diagnostics.
alias Lilly.Host.{Pool, ZFS}
root = "/run/source-permits"
host = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
pool_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
{:ok, identity} = ZFS.inspect_path("/pool")

{:ok, pool} =
  Pool.new(pool_id, "/pool", identity.filesystem_id,
    storage: OverallsProtocol.Storage.encode(identity.storage),
    host_id: host
  )

wire = "/run/export-descriptor.json" |> File.read!() |> JSON.decode!()
public = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 1::256>>)
command = "lilly-export-v4 #{wire["relocation_id"]}"

result =
  case System.fetch_env!("SOURCE_EXPORT_ACTION") do
    "run" -> Lilly.Transfer.SourceExport.run(root, pool, public, command)
    "revoke" -> Lilly.Transfer.SourceExport.revoke(root, host, wire["relocation_id"])
  end

File.write!("/run/source-export-result", inspect(result))
System.halt(if result == :ok, do: 0, else: 1)
