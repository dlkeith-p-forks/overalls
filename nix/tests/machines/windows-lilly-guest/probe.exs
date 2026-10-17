# @cc [owner:ghuntley,label:verification] windows-lilly-real-confined-execution
# This fixture MUST use the source-built Lilly release and the digest-verified
# Windows image, drive the production Driver for launch, trust, provisioning,
# restart, stop and delete, and assert each agent-set branch from durable
# journals. The agentless branch MUST NOT open terminals; the windows-v1 branch
# opens exactly one root ConPTY session per boot through Lilly's terminal
# client and retires it, and delivers one public workspace source through the
# production Driver (the nested test has no egress, so only the receiver's
# boot-bound acceptance is asserted). Neither branch fabricates a readiness
# receipt or prints terminal bytes; the serial boot log is read-only evidence.
defmodule WindowsLillyFixture do
  alias Lilly.Host.{Image, Pool, ZFS, ZFSDataset}
  alias Lilly.Lifecycle.Journal
  alias Lilly.Terminal.Vsock
  alias Lilly.VM.{Boot, Config, Driver, Jail, Observation, Spec, Unit}

  @spec run() :: :ok
  def run do
    host = "aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa"
    pool_id = "bbbbbbbb-bbbb-4bbb-8bbb-bbbbbbbbbbbb"
    {:ok, identity} = ZFS.inspect_path("/pool")

    {:ok, pool} =
      Pool.new(pool_id, "/pool", identity.filesystem_id,
        storage: OverallsProtocol.Storage.encode(identity.storage),
        host_id: host,
        # The image is read through the VM's shared store, which reports no
        # holes, so the 64 GiB disk is read in full (ADR-0173 decision 10);
        # production pools keep the 300 s default.
        image_io_timeout_ms: 1_800_000
      )

    {:ok, image} = Image.load(System.fetch_env!("WINDOWS_GUEST_IMAGE"))
    {:ok, agents} = OverallsProtocol.GuestAgents.parse(System.fetch_env!("WINDOWS_AGENTS"))
    true = image.manifest.boot_kind == :firmware and image.manifest.guest_agents == agents
    id = "dddddddd-dddd-4ddd-8ddd-000000000201"

    {:ok, spec} =
      Spec.new(%{
        id: id,
        image_id: image.id,
        pool_id: pool_id,
        profile: :customer,
        slot: 203,
        vcpu: 2,
        memory_bytes: 2_147_483_648,
        disk_bytes: image.manifest.minimum_disk_bytes
      })

    tools = System.fetch_env!("WINDOWS_RELEASE_METADATA") |> File.read!() |> JSON.decode!()
    {:ok, network} = Lilly.Network.Config.new(host, "eth1", [], "/var/lib/lilly/network")

    :ok =
      Lilly.Host.PrivateFiles.write(
        "/run/inception-storage-test",
        "smtp.json",
        JSON.encode!(%{
          "version" => 1,
          "host" => "smtp.example.test",
          "port" => 587,
          "username" => "fixture",
          "password" => "synthetic-storage-fixture",
          "from" => "dev@example.test",
          "tls" => "starttls"
        })
      )

    {:ok, config} =
      Config.new(%{
        state_dir: "/var/lib/lilly/vms",
        firecracker_logging: true,
        inception_smtp_file: "/run/inception-storage-test/smtp.json",
        inception_image_id: image.id,
        network: network,
        guest_trust_roots:
          System.fetch_env!("WINDOWS_GUEST_TRUST_ROOTS")
          |> String.split(",", trim: true)
          |> Enum.map(&File.read!/1),
        firecracker: tools["firecracker"],
        jailer: tools["jailer"],
        unshare: tools["unshare"]
      })

    true = config.guest_trust_roots != []
    generation = System.fetch_env!("WINDOWS_GENERATION") |> String.to_integer()
    directory = Path.join(config.state_dir, spec.id)

    case System.fetch_env!("WINDOWS_ACTION") do
      "start" ->
        :ok = Lilly.Network.setup(network)
        :ok = start(config, pool, image, spec, generation, deadline(120_000))
        await(fn -> Observation.running?(config, pool, spec) end, deadline(30_000))
        {:ok, boot} = Boot.read(directory)
        true = boot.generation == generation and boot.execution_epoch == 1
        guest_branch(agents, config, pool, spec, generation, directory)
        bundle_shape(pool, spec, agents)
        jail_shape(pool, spec, boot, agents)
        summary(config, spec, agents, directory)

      "restart" ->
        :ok = start(config, pool, image, spec, generation, deadline(120_000))
        await(fn -> Observation.running?(config, pool, spec) end, deadline(30_000))
        guest_branch(agents, config, pool, spec, generation, directory)
        summary(config, spec, agents, directory)

      "observe" ->
        true = Observation.running?(config, pool, spec)
        :ok = Driver.adopt(config, pool, spec, execution_epoch: 1, generation: generation)
        summary(config, spec, agents, directory)

      "stop" ->
        :ok = Driver.stop(config, pool, spec, generation: generation)

      "delete" ->
        :ok = Driver.delete(config, pool, spec, generation: generation)

      "reject-inception" ->
        {:ok, inception} = Lilly.Network.Guest.new(id, :inception, 203)

        {:error, :guest_agents_unavailable} =
          Driver.start(config, pool, image, %{spec | network: inception}, generation: generation)

        {:error, :enoent} = File.lstat(ZFSDataset.directory(pool, %{spec | network: inception}))
    end

    :ok
  end

  defp guest_branch(:none, config, pool, spec, generation, directory),
    do: agentless(config, pool, spec, generation, directory)

  defp guest_branch(:windows_v1, config, pool, spec, generation, directory),
    do: attested(config, pool, spec, generation, directory)

  # The windows-v1 branch: the guest's trust daemon installs the delivered roots
  # and answers the installed receipt bound to this boot; its readiness daemon
  # answers the ready line within the agent set's budget; both carry the same
  # guest boot UUID, which provisioning records.
  defp attested(config, pool, spec, generation, directory) do
    options = [execution_epoch: 1, generation: generation]
    {:ok, :windows_v1} = Driver.guest_agents(pool, spec)
    {:ok, boot} = Boot.read(directory)
    :ok = await_ok(fn -> Driver.trust(config, pool, spec, options) end, deadline(900_000))

    {:ok, %{state: :installed, payload: receipt}} =
      Journal.load(Lilly.Lifecycle.GuestTrust, directory, "guest-trust.json")

    true = receipt["boot_challenge"] == boot.boot_challenge
    true = is_binary(receipt["boot_id"]) and OverallsProtocol.uuid?(receipt["boot_id"])
    # The executor's completion path: wait for the guest's ready line within
    # the persisted deadline and commit provisioning for this exact boot.
    :ok = Driver.ready(config, pool, spec, options)
    :ok = Driver.provisioned(config, pool, spec, options)

    {:ok, %{state: :ready, payload: provisioning}} =
      Journal.load(Lilly.Lifecycle.Provisioning, directory, "provisioning.json")

    true = provisioning["boot_id"] == receipt["boot_id"]
    true = provisioning["boot_challenge"] == boot.boot_challenge
    true = provisioning["deadline"] - provisioning["launched_at"] == 600_000
    {:error, :guest_agents_unavailable} = Driver.unattested(config, pool, spec, options)
    true = Observation.running?(config, pool, spec)
    :ok = terminal(pool, spec, directory, generation)
    :ok = workspace(config, pool, spec, options)
    :ok
  end

  # ADR-0171 gate 5: overalls-workspaced-windows accepts a source-v2 delivery
  # bound to this boot and Lilly records it settled for this boot and source.
  defp workspace(config, pool, spec, options) do
    {:ok, source} = OverallsProtocol.WorkspaceSource.parse_url("https://github.com/octo/demo")
    sourced = %{spec | workspace_source: source}

    :ok =
      await_ok(
        fn -> Driver.deliver_workspace_source(config, pool, sourced, options) end,
        deadline(300_000)
      )

    true = Driver.workspace_source_settled?(config, sourced, options)
    :ok
  end

  # ADR-0171 gate 4: overalls-terminald on the guest authenticates this boot's
  # hello over vsock, lists root first, refuses an account the roster never
  # created, and runs a root PowerShell under ConPTY that prints a marker the
  # input alone cannot contain. The session is killed before returning.
  defp terminal(pool, spec, directory, generation) do
    {:ok, boot} = Boot.current(directory, spec.id, {1, generation})
    identity = Map.put(boot, :uds_path, Path.join(Jail.root(pool, spec), "v.sock"))
    control = connect(identity, deadline(300_000))
    :ok = Vsock.ping(control)
    {:ok, ["root" | _]} = Vsock.users(control)
    {:error, :rejected} = Vsock.create(control, "u200000", "xterm-256color", 200, 50)
    {:ok, created} = Vsock.create(control, "root", "xterm-256color", 200, 50, timeout: 30_000)

    {:ok, attached} =
      Vsock.attach(identity, created.guest_session_id, created.attach_token, :rw, 0,
        cols: 200,
        rows: 50
      )

    marker = Base.encode16(:crypto.strong_rand_bytes(6))
    :ok = Vsock.write(attached.socket, "Write-Output ('KT' + '#{marker}' + 'OK')\r")
    :ok = wait(attached.socket, "KT#{marker}OK", deadline(180_000), attached.replay)
    :ok = Vsock.kill(control, created.guest_session_id)
    Vsock.close(attached.socket)
    Vsock.close(control)
    :ok
  end

  defp connect(identity, until) do
    case Vsock.connect(identity, timeout: 2_000) do
      {:ok, control} ->
        control

      {:error, reason} ->
        if System.monotonic_time(:millisecond) >= until,
          do: raise("terminald unreachable: #{inspect(reason)}")

        Process.sleep(2_000)
        connect(identity, until)
    end
  end

  defp wait(socket, marker, until, tail) do
    if System.monotonic_time(:millisecond) >= until,
      do: raise("terminal marker timed out; terminal bytes withheld")

    body = :binary.replace(tail, "\r", "", [:global])

    if :binary.match(body, marker) != :nomatch do
      :ok
    else
      keep = binary_part(body, byte_size(body) - min(byte_size(body), 4096), min(byte_size(body), 4096))

      case :gen_tcp.recv(socket, 0, 1000) do
        {:ok, bytes} -> wait(socket, marker, until, keep <> bytes)
        {:error, :timeout} -> wait(socket, marker, until, keep)
        _ -> raise "terminal closed before the marker; terminal bytes withheld"
      end
    end
  end

  defp await_ok(fun, until) do
    case fun.() do
      :ok ->
        :ok

      {:error, reason} ->
        if System.monotonic_time(:millisecond) < until do
          Process.sleep(5_000)
          await_ok(fun, until)
        else
          raise "guest delivery did not succeed: #{inspect(reason)}"
        end
    end
  end

  # The agentless branch: trust recorded as skipped for this exact boot,
  # provisioning committed as unattested, and the readiness entry point refused.
  defp agentless(config, pool, spec, generation, directory) do
    options = [execution_epoch: 1, generation: generation]
    :ok = Driver.trust(config, pool, spec, options)
    {:ok, boot} = Boot.read(directory)

    {:ok, %{state: :skipped, payload: receipt}} =
      Journal.load(Lilly.Lifecycle.GuestTrust, directory, "guest-trust.json")

    true = receipt["boot_challenge"] == boot.boot_challenge and receipt["boot_id"] == nil
    {:ok, :none} = Driver.guest_agents(pool, spec)
    :ok = Driver.unattested(config, pool, spec, options)
    :ok = Driver.unattested(config, pool, spec, options)

    {:ok, %{state: :unattested, payload: provisioning}} =
      Journal.load(Lilly.Lifecycle.Provisioning, directory, "provisioning.json")

    true =
      provisioning["boot_id"] == nil and provisioning["boot_challenge"] == boot.boot_challenge

    {:error, :guest_agents_unavailable} = Driver.ready(config, pool, spec, options)
    true = Observation.running?(config, pool, spec)
    :ok
  end

  defp bundle_shape(pool, spec, agents) do
    dataset = ZFSDataset.directory(pool, spec)
    {:ok, names} = File.ls(dataset)
    ["boot-bundle.json", "firmware", "rootfs.ext4"] = Enum.sort(names)
    {:ok, bundle} = Lilly.VM.WorkloadBundle.load(dataset, spec)
    true = bundle.boot_kind == :firmware and bundle.guest_agents == agents and bundle.pci
    wire = OverallsProtocol.GuestAgents.wire(agents)

    %{"version" => 2, "boot" => "firmware", "pci" => true, "guest_agents" => ^wire} =
      dataset |> Path.join("boot-bundle.json") |> File.read!() |> JSON.decode!()

    {:ok, %File.Stat{size: 4_194_304, mode: mode}} = File.stat(Path.join(dataset, "firmware"))
    true = Bitwise.band(mode, 0o777) == 0o444
    :ok
  end

  defp jail_shape(pool, spec, boot, agents) do
    root = Jail.root(pool, spec)
    configuration = root |> Path.join("firecracker.json") |> File.read!() |> JSON.decode!()
    %{"kernel_image_path" => "/firmware"} = configuration["boot-source"]
    false = Map.has_key?(configuration["boot-source"], "boot_args")

    true =
      Map.has_key?(configuration, "vsock") == OverallsProtocol.GuestAgents.vsock?(agents)

    %{"hyperv" => true} = configuration["cpu-config"]
    %{"version" => "V2", "network_interfaces" => ["eth0"]} = configuration["mmds-config"]
    {:ok, %File.Stat{mode: mode}} = File.stat(Path.join(root, "metadata.json"))
    true = Bitwise.band(mode, 0o777) == 0o444
    %{"lilly" => lilly} = root |> Path.join("metadata.json") |> File.read!() |> JSON.decode!()
    true = lilly["ipv4"] == spec.network.address and lilly["gateway"] == spec.network.gateway
    true = lilly["boot_challenge"] == boot.boot_challenge and lilly["prefix_length"] == 32
    false = Map.has_key?(lilly, "generation")
    :ok
  end

  # Facts the Python driver needs to reach the guest from the host side.
  defp summary(config, spec, agents, directory) do
    boot_id =
      case Journal.load(Lilly.Lifecycle.Provisioning, directory, "provisioning.json") do
        {:ok, %{payload: %{"boot_id" => boot_id}}} -> boot_id
        _ -> nil
      end

    IO.puts(
      JSON.encode!(%{
        address: spec.network.address,
        gateway: spec.network.gateway,
        namespace: config.network.namespace,
        tap: spec.network.tap,
        guard: spec.network.guard,
        boot_log: Unit.boot_log(config, spec),
        placement: spec.id,
        agents: OverallsProtocol.GuestAgents.wire(agents),
        boot_id: boot_id
      })
    )
  end

  defp start(config, pool, image, spec, generation, until) do
    ready = Path.join(ZFSDataset.metadata_directory(pool, spec), "disk-ready.json")

    result =
      if File.exists?(ready),
        do: Driver.restart(config, pool, spec, generation: generation),
        else: Driver.start(config, pool, image, spec, generation: generation)

    case result do
      {:error, :storage_busy} = result ->
        if System.monotonic_time(:millisecond) < until do
          Process.sleep(100)
          start(config, pool, image, spec, generation, until)
        else
          result
        end

      result ->
        result
    end
  end

  defp await(fun, until) do
    unless fun.() do
      if System.monotonic_time(:millisecond) >= until, do: raise("VMM readiness timed out")

      receive do
      after
        100 -> await(fun, until)
      end
    end
  end

  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms
end

:ok = WindowsLillyFixture.run()
