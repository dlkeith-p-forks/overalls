# @cc [owner:ghuntley,label:deployment] inception-native-enrollment-request
# Enrollment MUST describe the actual guest machine and ZFS GUIDs using Lilly's
# native readers. No simulated inventory or host capacity may enable scheduling.
identity = "/var/lib/inception/identity.json" |> File.read!() |> JSON.decode!()
{:ok, machine} = Lilly.Host.Identity.read()
{:ok, pool} = Lilly.Host.ZFS.inspect_path("/pool")

request = %{
  version: 3,
  name: "inception-" <> identity["instance_id"],
  architecture: "x86_64",
  machine_id: machine,
  overhead_cores: 0,
  overhead_memory_bytes: 0,
  credential_ttl_seconds: 157_680_000,
  pools: [%{
    name: "guests",
    storage: OverallsProtocol.Storage.encode(pool.storage),
    overhead_bytes: 0
  }]
}

:ok = Lilly.Host.PrivateFiles.write("/var/lib/inception", "enrollment-request.json", JSON.encode!(request))
