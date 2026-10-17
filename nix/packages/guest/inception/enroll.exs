# @cc [owner:ghuntley,label:security;recovery] inception-private-idempotent-enrollment
# Bootstrap MUST use production image and enrollment APIs with a durable operation
# ID. Existing credentials MUST be verified, not rotated on restart. The private
# envelope MUST remain in guest-local state; diagnostics may not contain it.
Application.put_env(:marshall, :operator_mode, true)
{:ok, _} = Application.ensure_all_started(:marshall)

state = "/var/lib/inception"
config = System.fetch_env!("INCEPTION_CONFIG") |> File.read!() |> JSON.decode!()
identity = Path.join(state, "identity.json") |> File.read!() |> JSON.decode!()
# The nested guest image is rebuilt by inception-image.service with this
# instance's public private-service root; enrollment never registers an
# image without instance trust.
guest_image = Path.join(state, "guest-image")
manifest = Path.join(guest_image, "manifest.json") |> File.read!() |> JSON.decode!()
{:ok, _} = Marshall.Compute.Images.register(manifest, "NixOS")
credential = Path.join(state, "lilly-credential.json")

if File.exists?(credential) do
  {:ok, _} = Marshall.Compute.Enrollment.verify_file(credential)
else
  # Preparation re-exports the same active credential if publication was interrupted.
  temporary = Path.join(state, "enrollment-output.json")
  case File.lstat(temporary) do
    {:error, :enoent} -> :ok
    {:ok, %File.Stat{type: :regular, uid: 0, links: 1}} -> File.rm!(temporary)
  end

  {:ok, _} = Marshall.Compute.EnrollmentPreparation.prepare_file(
    identity["enrollment_operation_id"], :prepare,
    Path.join(state, "enrollment-request.json"), temporary
  )

  :ok = File.rename(temporary, credential)
  {_, 0} = System.cmd(config["sync"], ["--", credential, state], stderr_to_stdout: true)
end

{:ok, host} = Marshall.Compute.Enrollment.describe("inception-" <> identity["instance_id"])
tools = Path.join(config["lilly_release"], "overalls-release.json") |> File.read!() |> JSON.decode!()

# Resolve the deployed account instead of assuming a numeric UID. The connector
# checks this exact peer UID independently of Unix group access.
{audi_uid_text, 0} = System.cmd(config["id"], ["-u", "audi"], stderr_to_stdout: true)
{audi_uid, ""} = Integer.parse(String.trim(audi_uid_text))
true = audi_uid in 1..4_294_967_294

lilly = %{
  version: 3, host_id: host.host_id,
  control_plane: "https://localhost:5443",
  cacertfile: "/run/inception-public/ca.crt",
  credential_file: credential,
  state_dir: "/var/lib/lilly/control",
  cgroup_path: "/sys/fs/cgroup/lilly.slice",
  images: [guest_image],
  ingress: %{path: "/run/lilly-ingress/audi.sock", audi_uid: audi_uid},
  pools: Enum.map(host.pools, &Map.put(&1, :path, "/pool")),
  execution: Map.merge(Map.take(tools, ~w(firecracker jailer unshare)), %{
    "state_dir" => "/var/lib/lilly/vms",
    "network_state_dir" => "/var/lib/lilly/network",
    "egress_interface" => "eth0",
    "protected_cidrs" => [],
    "audi_ingress" => true,
    "private_services" => true
  })
}

temporary = Path.join(state, "lilly.json.new")
case File.lstat(temporary) do
  {:error, :enoent} -> :ok
  {:ok, %File.Stat{type: :regular, uid: 0, links: 1}} -> File.rm!(temporary)
end
:ok = Marshall.Operations.PrivateFiles.with_new(temporary, fn file ->
  Marshall.Operations.PrivateFiles.write_sync(file, temporary, JSON.encode!(lilly))
end)
:ok = File.rename(Path.join(state, "lilly.json.new"), Path.join(state, "lilly.json"))
{_, 0} = System.cmd(config["sync"], ["--", Path.join(state, "lilly.json"), state], stderr_to_stdout: true)
