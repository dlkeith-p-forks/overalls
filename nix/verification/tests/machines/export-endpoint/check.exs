alias Lilly.Host.{Pool, Storage, ZFS}
alias Lilly.Transfer.{DestinationRevocation, Key, Permit, Receiver, SSH, SourceRevocation}
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

          {:ok, {:receive, _} = consumer} =
            Storage.locked(pool, fn ->
              {:ok, _} = Lilly.Transfer.ReceivedDataset.prepare(pool, descriptor)
              Lilly.Transfer.ReceivedDataset.fresh_receiver(pool, descriptor)
            end)

          # 256 KiB/s for five seconds feeds the real receive about 1.3 MiB
          # of the stream before its deadline kills it, leaving resumable state.
          {:error, :stream_timeout} =
            SSH.pull(root, request, endpoint, consumer, 5000, nil, 262_144)

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

        # Lilly can no longer name a remote command (hostd fixes the verb), so
        # this client presents the relocation's real key with a chosen one.
        {output, status} =
          System.cmd(
            System.find_executable("ssh"),
            [
              "-F", "/dev/null", "-T", "-n", "-i", files.identity_file,
              "-o", "IdentitiesOnly=yes", "-o", "IdentityAgent=none",
              "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
              "-o", "UserKnownHostsFile=" <> files.known_hosts,
              "-o", "GlobalKnownHostsFile=/dev/null",
              "-o", "HostKeyAlias=lilly-" <> request.source_host_id,
              "-p", Integer.to_string(endpoint["port"]), "-l", "lilly-transfer",
              "--", endpoint["address"], "touch /run/export-injection"
            ],
            stderr_to_stdout: false
          )

        true = status != 0
        File.write!("/run/rejected", output)

      "blocked" ->
        # A one-byte-per-second receive into a throwaway placement holds the
        # sender blocked on its pipe until cancellation reaches it.
        {:ok, identity} = ZFS.inspect_path("/import-pool")

        consumer =
          {:receive,
           %{
             dataset: identity.storage.dataset,
             pool: identity.path,
             placement: Lilly.UUID.generate(),
             host: request.host_id,
             pool_id: wire["destination"]["pool_id"],
             nonce: Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
           }}

        {:error, _} = SSH.pull(root, request, endpoint, consumer, 120_000, nil, 1)
        File.write!("/run/client-cancelled", "confirmed")

      "refused" ->
        consumer = {:compare, "/dev/null"}
        {:error, _} = SSH.pull(root, request, endpoint, consumer, 30_000)
    end
  end
end
