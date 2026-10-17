alias Lilly.Host.{Pool, Storage, ZFS}
alias Lilly.Transfer.{DestinationRevocation, Key, Permit, Receiver, SSH, SourceRevocation, Stream}
wire = File.read!("/run/export-descriptor.json") |> JSON.decode!()
role = System.fetch_env!("ENDPOINT_ROLE")
action = System.fetch_env!("ENDPOINT_ACTION")
root = "/run/transfer-client"
permit_root = "/run/source-permits"

if role == "source" do
  host = wire["source"]["host_id"]
  {:ok, identity} = ZFS.inspect_path("/pool")

  {:ok, pool} =
    Pool.new(wire["source"]["pool_id"], "/pool", identity.filesystem_id,
      host_id: host,
      storage: OverallsProtocol.Storage.encode(identity.storage)
    )

  case action do
    configure when configure in ["configure", "configure-probe"] ->
      config = %{
        "version" => 3,
        "host_id" => host,
        "root" => permit_root,
        "pools" => [
          %{
            "id" => pool.id,
            "path" => pool.path,
            "filesystem_id" => pool.filesystem_id,
            "storage" => OverallsProtocol.Storage.encode(pool.storage)
          }
        ]
      }

      File.write!("/run/transfer-config.json", JSON.encode!(config))
      File.chmod!("/run/transfer-config.json", 0o600)
      {:ok, _} = Lilly.Transfer.Endpoint.load("/run/transfer-config.json")
      public = File.read!("/run/peer-public")

      if configure == "configure-probe" do
        now = System.system_time(:second)

        :ok =
          Lilly.Transfer.PermitJournal.probe(
            permit_root,
            Map.delete(wire, "stream"),
            public,
            "aaaaaaaa-aaaa-4aaa-8aaa-000000000099",
            1,
            now + 300,
            now
          )
      else
        :ok =
          Storage.locked(pool, fn ->
            Permit.issue(permit_root, pool, wire, public, 1, System.system_time(:second) + 300)
          end)
      end

    "revoke" ->
      command = %{
        id: wire["relocation_id"],
        host_id: host,
        placement_id: wire["source"]["placement_id"],
        execution_epoch: wire["source_epoch"],
        expires_at: System.system_time(:second) + 180
      }

      {:ok, receipt} = SourceRevocation.execute(permit_root, host, command)
      {:ok, ^receipt} = SourceRevocation.execute(permit_root, host, command)

    "renew" ->
      public = File.read!("/run/peer-public")

      :ok =
        Storage.locked(pool, fn ->
          {:ok, current} =
            Lilly.Transfer.PermitJournal.for_key(
              permit_root,
              host,
              public,
              System.system_time(:second)
            )

          revision = current.revision + 1

          Permit.issue(
            permit_root,
            pool,
            wire,
            public,
            revision,
            System.system_time(:second) + 300
          )
        end)
  end
else
  request = %{
    host_id: wire["destination"]["host_id"],
    source_host_id: wire["source"]["host_id"],
    relocation_id: wire["relocation_id"],
    placement_id: wire["destination"]["placement_id"]
  }

  if action == "key" do
    :ok = Lilly.Host.PrivateFiles.directory(root)
    {:ok, public} = Key.ensure(root, request.host_id, request.relocation_id, request.placement_id)
    File.write!("/run/peer-public", public)
  else
    [algorithm, encoded | _] = File.read!("/run/source-host.pub") |> String.split()
    endpoint = %{"address" => "source", "port" => 2222, "host_key" => algorithm <> " " <> encoded}

    case action do
      cancel when cancel in ["cancel-busy", "cancel"] ->
        command = %{
          id: request.relocation_id,
          host_id: request.host_id,
          placement_id: request.placement_id,
          execution_epoch: wire["destination_epoch"],
          expires_at: System.system_time(:second) + 180
        }

        if cancel == "cancel-busy" do
          {:error, :destination_revocation_unconfirmed} =
            DestinationRevocation.execute(root, request.host_id, command)
        else
          {:ok, receipt} = DestinationRevocation.execute(root, request.host_id, command)
          {:ok, ^receipt} = DestinationRevocation.execute(root, request.host_id, command)
        end

        false = File.exists?(Path.join([root, "transfers", request.relocation_id, "id_ed25519"]))

        {:error, _} =
          Key.ensure(root, request.host_id, request.relocation_id, request.placement_id)

      probe when probe in ["probe", "probe-refused"] ->
        challenge = "aaaaaaaa-aaaa-4aaa-8aaa-000000000099"

        if probe == "probe" do
          :ok = SSH.probe(root, request, endpoint, challenge, 30_000)

          {:error, _} =
            SSH.probe(root, request, endpoint, "aaaaaaaa-aaaa-4aaa-8aaa-000000000098", 30_000)
        else
          {:error, _} = SSH.probe(root, request, endpoint, challenge, 30_000)
        end

      value when value in ["pull", "partial"] ->
        {:ok, identity} = ZFS.inspect_path("/import-pool")

        {:ok, pool} =
          Pool.new(wire["destination"]["pool_id"], identity.path, identity.filesystem_id,
            host_id: request.host_id,
            storage: OverallsProtocol.Storage.encode(identity.storage)
          )

        if value == "partial" do
          {:ok, descriptor} = OverallsProtocol.Relocation.descriptor(wire)

          {:ok, {executable, arguments}} =
            Storage.locked(pool, fn ->
              {:ok, _} = Lilly.Transfer.ReceivedDataset.prepare(pool, descriptor)
              Lilly.Transfer.ReceivedDataset.fresh_receiver(pool, descriptor)
            end)

          consumer =
            {System.find_executable("python3"),
             ["/etc/partial-receive.py", executable | arguments]}

          {:error, _} = SSH.pull(root, request, endpoint, consumer, 120_000)

          fetched =
            Storage.locked(pool, fn ->
              Lilly.Transfer.ReceivedDataset.resume_token(pool, descriptor)
            end)

          true = match?({:ok, token} when is_binary(token), fetched)
        else
          owner = self()
          {:ok, guid} = Receiver.pull(root, pool, wire, endpoint, 120_000, 67_108_864, owner)

          receive do
            {:lilly_transfer_progress, ^owner, count} when count > 0 -> :ok
          after
            1000 -> raise "Missing receiver transport progress"
          end

          {:ok, ^guid} = Receiver.pull(root, pool, wire, endpoint, 120_000)
        end

        false = File.exists?(Path.join([pool.path, ".lilly-zfs", "active", request.placement_id]))

      "bad-command" ->
        {:ok, files} =
          Key.connection(
            root,
            request.host_id,
            request.relocation_id,
            request.placement_id,
            request.source_host_id,
            endpoint
          )

        {:ok, {ssh, args}} = SSH.command(endpoint, request, files)
        consumer = {System.find_executable("dd"), ["of=/run/rejected", "status=none"]}

        {:error, _} =
          Stream.run(
            files.stream_dir,
            {ssh, List.replace_at(args, -1, "touch /run/export-injection")},
            consumer,
            30_000
          )

      "blocked" ->
        consumer = {System.find_executable("python3"), ["-c", "import time; time.sleep(120)"]}
        {:error, _} = SSH.pull(root, request, endpoint, consumer, 120_000)
        File.write!("/run/client-cancelled", "confirmed")

      "refused" ->
        consumer = {System.find_executable("dd"), ["of=/run/refused", "status=none"]}
        {:error, _} = SSH.pull(root, request, endpoint, consumer, 30_000)
    end
  end
end
