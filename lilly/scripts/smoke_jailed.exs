# Root-only, real KVM/ZFS/systemd/nftables integration. See lilly/README.md.
Code.require_file("console_probe.exs", __DIR__)
Code.require_file("zfs_fixture.exs", __DIR__)

defmodule Lilly.JailedSmoke do
  alias Lilly.Console.Dtach
  alias Lilly.Host.{Command, Image, Pool, PrivateFiles}
  alias Lilly.VM.{Config, Disk, Driver, Intent, Observation, Spec, Unit}

  def run(["worker", operation, context_path, id]) do
    {:ok, bytes} = PrivateFiles.read_secret(context_path)
    context = JSON.decode!(bytes)
    {config, pool, image, specs} = load(context)
    spec = Enum.find(specs, &(&1.id == id)) || raise("unknown smoke VM")

    result =
      case operation do
        "start" ->
          Driver.start(config, pool, image, spec)

        "stop" ->
          Driver.stop(config, pool, spec)

        "delete" ->
          Driver.delete(config, pool, spec)

        "reject" ->
          case Driver.start(config, pool, image, spec) do
            {:error, _} -> :ok
            _ -> :unexpected_start
          end
      end

    if result != :ok, do: raise("VM worker failed: #{inspect(result)}")
    IO.puts("worker ok")
  end

  def run(args) do
    {opts, [], []} =
      OptionParser.parse(args,
        strict: [
          guest: :string,
          firecracker: :string,
          jailer: :string,
          dtach: :string,
          unshare: :string,
          elixir: :string,
          egress: :string,
          zfs_parent_dataset: :string
        ]
      )

    {:ok, %File.Stat{uid: 0}} = File.stat("/proc/self")
    token = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    state = "/tmp/lilly-#{token}"
    pool_path = "/tmp/ls-#{token}"
    :ok = PrivateFiles.directory(state)
    :ok = PrivateFiles.directory(state <> "/network")

    fixture =
      Lilly.ZFSFixture.create(Keyword.fetch!(opts, :zfs_parent_dataset), pool_path, uuid())

    {:ok, image} = Image.load(Keyword.fetch!(opts, :guest))
    pool_id = uuid()

    context = %{
      "state" => state,
      "pool" => pool_path,
      "pool_id" => pool_id,
      "host_id" => uuid(),
      "guest" => image.path,
      "tools" =>
        Map.new(
          for key <- [:firecracker, :jailer, :dtach, :unshare],
              do: {Atom.to_string(key), Keyword.fetch!(opts, key)}
        ),
      "egress" => Keyword.fetch!(opts, :egress),
      "specs" =>
        for({profile, slot} <- [{:customer, 2}, {:customer, 3}, {:oss, 2}]) do
          {:ok, spec} =
            Spec.new(%{
              id: uuid(),
              image_id: image.id,
              pool_id: pool_id,
              profile: profile,
              slot: slot,
              vcpu: 1,
              memory_bytes: 536_870_912,
              disk_bytes: 3_221_225_472
            })

          Spec.encode(spec)
        end
    }

    :ok = PrivateFiles.write(state, "smoke.json", JSON.encode!(context))
    context_path = state <> "/smoke.json"
    {config, pool, _image, specs} = load(context)
    Process.put(:smoke_sockets, [])

    try do
      :ok = Lilly.Network.setup(config.network)
      :ok = Lilly.Network.setup(config.network)
      network_recovery(config, hd(specs))
      generation_fence(config, pool, image, hd(specs))

      for spec <- specs do
        worker(opts, "start", context_path, spec.id)

        await(
          fn -> Observation.running?(config, pool, spec) end,
          30_000,
          "VMM isolation/readiness"
        )
      end

      IO.puts(
        "Three jailed VMMs survive their launching BEAM processes; identity and resource limits verified."
      )

      sockets =
        for spec <- specs do
          socket = connect(config, spec)
          command(socket, "test \"$(id -u)\" = 0")

          command(
            socket,
            "systemd-run --quiet --unit=lilly-probe --socket-property=ListenStream=18080 --property=StandardInput=socket /run/current-system/sw/bin/cat"
          )

          command(socket, "timeout 2 bash -c 'echo test >/dev/tcp/127.0.0.1/18080'")
          internet(socket, spec)
          command(socket, "test \"$(cat /sys/block/vda/queue/discard_max_bytes)\" = 0")
          socket
        end

      IO.puts(
        "Root consoles, profile egress policy, local TCP listeners and disabled block discard verified."
      )

      for {spec, socket} <- Enum.zip(specs, sockets), other <- specs, other.id != spec.id do
        denied(socket, other.network.address, 18080)
      end

      IO.puts("All six same-profile/cross-profile TCP paths are denied.")
      host_denials(config, hd(sockets), hd(specs))
      spoof_denials(config, hd(sockets), hd(specs))

      IO.puts(
        "Host/private destinations, source IP/MAC spoofing, VLAN and IPv6 traffic are denied."
      )

      first = hd(specs)
      socket = hd(sockets)
      command(socket, "printf '#{token}' >/root/lilly-smoke-marker; sync")
      :ok = Dtach.close(socket)
      Lilly.ConsoleProbe.run(config, pool, first, context["host_id"])
      socket = connect(config, first)
      marker(socket, token)
      :ok = Dtach.close(socket)
      worker(opts, "stop", context_path, first.id)
      {:ok, :stopped} = Unit.status(first)
      true = File.exists?(Disk.path(pool, first))
      missing_disk_fails(config, pool, first, context["guest"])
      worker(opts, "start", context_path, first.id)
      await(fn -> Observation.running?(config, pool, first) end, 30_000, "restarted VMM")
      socket = connect(config, first)
      marker(socket, token)
      internet(socket, first)
      :ok = Dtach.close(socket)
      IO.puts("Console reattachment and persistent disk across API shutdown/start verified.")

      {:ok, snapshot} = Pool.snapshot(pool)
      true = Enum.all?(specs, &(snapshot.allocations[&1.id] == &1.disk_bytes))

      for spec <- specs do
        worker(opts, "delete", context_path, spec.id)
        worker(opts, "reject", context_path, spec.id)
        false = File.exists?(Disk.path(pool, spec))
      end

      IO.puts(
        "Full disk allocation credit and cleanup-before-deletion verified; tombstones reject restart."
      )
    after
      Enum.each(Process.get(:smoke_sockets, []), &Dtach.close/1)

      results =
        for spec <- specs do
          if File.exists?(Path.join([state, spec.id, "vm.json"])),
            do: Driver.delete(config, pool, spec),
            else: :ok
        end

      if Enum.all?(results, &(&1 == :ok)) and Lilly.Network.destroy(config.network) == :ok and
           Lilly.Network.destroy(config.network) == :ok do
        File.rm_rf!(state)
        Lilly.ZFSFixture.destroy(fixture)
        IO.puts("Owned units, mounts, disks, TAPs, namespace and firewall tables cleaned up.")
      else
        raise "Cleanup remains unconfirmed; retained state at #{state} and #{pool.path}"
      end
    end

    IO.puts("Jailed KVM smoke passed.")
  end

  defp load(context) do
    {:ok, net} =
      Lilly.Network.Config.new(
        context["host_id"],
        context["egress"],
        [],
        context["state"] <> "/network"
      )

    {:ok, config} =
      Config.new(%{
        state_dir: context["state"],
        network: net,
        firecracker: context["tools"]["firecracker"],
        jailer: context["tools"]["jailer"],
        dtach: context["tools"]["dtach"],
        unshare: context["tools"]["unshare"]
      })

    {:ok, identity} = Pool.inspect_path(context["pool"])

    {:ok, pool} =
      Pool.new(context["pool_id"], context["pool"], identity.filesystem_id,
        storage: OverallsProtocol.Storage.encode(identity.storage),
        host_id: context["host_id"]
      )

    {:ok, image} = Image.load(context["guest"])

    specs =
      for value <- context["specs"] do
        profile =
          case value["profile"] do
            "customer" -> :customer
            "oss" -> :oss
          end

        {:ok, spec} =
          Spec.new(%{
            id: value["id"],
            image_id: value["image_id"],
            pool_id: value["pool_id"],
            profile: profile,
            slot: value["slot"],
            vcpu: value["vcpu"],
            memory_bytes: value["memory_bytes"],
            disk_bytes: value["disk_bytes"]
          })

        spec
      end

    {config, pool, image, specs}
  end

  defp generation_fence(config, pool, image, template) do
    {:ok, spec} =
      template
      |> Map.take([:id, :image_id, :pool_id, :profile, :slot, :vcpu, :memory_bytes, :disk_bytes])
      |> Map.merge(%{id: uuid(), slot: 4, profile: template.network.profile})
      |> Spec.new()

    try do
      # Stop may arrive before provisioning ever materializes a disk.
      :ok = Driver.stop(config, pool, spec, generation: 2)
      {:ok, :stopped} = Unit.status(spec)
      false = File.exists?(Disk.path(pool, spec))
      {:error, :stale_generation} = Driver.start(config, pool, image, spec, generation: 1)

      # Simulate a delayed systemd start accepted before the newer stop intent.
      # The in-service guard must exit without entering jailer or creating a VMM.
      :ok = Lilly.Host.PrivateFiles.directory(Path.join(config.state_dir, spec.id))
      {:ok, lock} = Lilly.Host.Lock.acquire(Path.join([config.state_dir, spec.id, "lock"]))

      try do
        :ok =
          Unit.start(config, pool, spec, %{
            placement_id: spec.id,
            execution_epoch: 1,
            generation: 1,
            state: :running
          })
      after
        Lilly.Host.Lock.release(lock)
      end

      await(fn -> Unit.status(spec) == {:ok, :stopped} end, 5000, "stale unit fence")
      false = File.exists?(Disk.path(pool, spec))
      :ok = Driver.fail(config, pool, spec, execution_epoch: 1, generation: 3)
      {:error, :generation_conflict} = Driver.start(config, pool, image, spec, generation: 3)
      :ok = Driver.delete(config, pool, spec, generation: 4)
      {:ok, %{generation: 4, state: :deleted}} = Intent.read(Path.join(config.state_dir, spec.id))
      {:error, _} = Driver.start(config, pool, image, spec, generation: 5)
      :ok = Driver.delete(config, pool, spec, generation: 4)
      false = File.exists?(Disk.path(pool, spec))

      IO.puts(
        "Stop before first boot, delayed systemd launch, failed generation and deletion fences verified."
      )
    after
      :ok = Driver.delete(config, pool, spec)
    end
  end

  defp network_recovery(config, spec) do
    :ok = Lilly.Network.attach(config.network, spec.network)
    {:error, :network_cleanup_unconfirmed} = Lilly.Network.destroy(config.network)

    {:ok, _} =
      Command.in_namespace(config.network.namespace, :ip, [
        "link",
        "set",
        "dev",
        spec.network.tap,
        "alias",
        ""
      ])

    :ok = Lilly.Network.attach(config.network, spec.network)
    :ok = Lilly.Network.detach(config.network, spec.network)
    IO.puts("Partial TAP alias setup recovers; namespace cleanup rejects retained TAPs.")
  end

  defp missing_disk_fails(config, pool, spec, image_path) do
    {:ok, image} = Image.load(image_path)
    disk = Disk.path(pool, spec)
    File.rename!(disk, disk <> ".saved")

    try do
      {:error, :disk_prepare_failed} = Driver.start(config, pool, image, spec)
      false = File.exists?(disk)
    after
      File.rename!(disk <> ".saved", disk)
    end

    IO.puts("A missing previously ready disk is rejected without reimaging it.")
  end

  defp worker(opts, operation, context, id) do
    paths =
      Enum.flat_map([Lilly.VM.Driver, OverallsProtocol], fn module ->
        ["-pa", module |> :code.which() |> List.to_string() |> Path.dirname()]
      end)

    # The child emits fixed diagnostic results, never terminal bytes.
    case System.cmd(
           Keyword.fetch!(opts, :elixir),
           paths ++ [__ENV__.file, "worker", operation, context, id],
           stderr_to_stdout: true
         ) do
      {"worker ok\n", 0} -> :ok
      {_output, _} -> raise "independent VM worker failed during #{operation}"
    end
  end

  defp host_denials(config, socket, spec) do
    {:ok, body} = Command.run(:ip, ["-4", "-j", "addr", "show", "dev", config.network.egress])
    [interface] = JSON.decode!(body)
    address = Enum.find(interface["addr_info"], &(&1["scope"] == "global"))["local"]
    {:ok, ip} = :inet.parse_ipv4_address(String.to_charlist(address))
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: ip])
    {:ok, {_, port}} = :inet.sockname(listener)

    try do
      denied(socket, address, port)

      for address <- [spec.network.gateway, "169.254.255.1", "169.254.169.254"],
          do: denied(socket, address, port)
    after
      :gen_tcp.close(listener)
    end
  end

  defp spoof_denials(config, socket, spec) do
    checks = [
      {"ip addr add 10.10.0.3/32 dev eth0", "--interface 10.10.0.3",
       "ip addr del 10.10.0.3/32 dev eth0"},
      {"ip link set eth0 address 02:00:00:00:00:99", "",
       "ip link set eth0 address #{spec.network.mac}"},
      {"ip link add link eth0 name probe7 type vlan id 7; ip link set probe7 up; ip addr add #{spec.network.address}/32 dev probe7; ip route add 1.1.1.1/32 via #{spec.network.gateway} dev probe7 onlink",
       "--interface probe7", "ip route del 1.1.1.1/32; ip link del probe7"}
    ]

    for {setup, options, cleanup} <- checks do
      before = guard_drops(config, spec)

      command(
        socket,
        "#{setup}; curl --silent --connect-timeout 2 --max-time 3 #{options} https://1.1.1.1/ -o /dev/null; result=$?; #{cleanup}; test \"$result\" = 28"
      )

      true = guard_drops(config, spec) > before
    end

    before = guard_drops(config, spec)

    command(
      socket,
      "sysctl -qw net.ipv6.conf.all.disable_ipv6=0 net.ipv6.conf.default.disable_ipv6=0 net.ipv6.conf.eth0.disable_ipv6=0"
    )

    await(fn -> guard_drops(config, spec) > before end, 5000, "IPv6 ingress guard")

    command(
      socket,
      "sysctl -qw net.ipv6.conf.all.disable_ipv6=1 net.ipv6.conf.default.disable_ipv6=1"
    )

    internet(socket, spec)
  end

  defp guard_drops(config, spec) do
    {:ok, body} =
      Command.in_namespace(config.network.namespace, :nft, [
        "--json",
        "list",
        "table",
        "netdev",
        spec.network.guard
      ])

    for %{"rule" => %{"expr" => expressions}} <- JSON.decode!(body)["nftables"],
        Enum.any?(expressions, &Map.has_key?(&1, "drop")),
        %{"counter" => %{"packets" => packets}} <- expressions,
        reduce: 0 do
      total -> total + packets
    end
  end

  defp denied(socket, address, port),
    do:
      command(
        socket,
        "timeout 2 bash -c 'echo probe >/dev/tcp/#{address}/#{port}' >/dev/null 2>&1; test \"$?\" = 124"
      )

  defp internet(socket, %{network: %{profile: :customer}}) do
    denied(socket, "1.1.1.1", 443)
  end

  defp internet(socket, _spec),
    do: command(socket, "curl --silent --fail --max-time 20 https://example.com/ -o /dev/null")

  defp marker(socket, token),
    do: command(socket, "test \"$(cat /root/lilly-smoke-marker)\" = '#{token}'")

  defp connect(config, spec) do
    {:ok, socket} = Dtach.connect(Unit.console(config, spec))
    Process.put(:smoke_sockets, [socket | Process.get(:smoke_sockets, [])])
    :ok = Dtach.write(socket, "\n")
    wait(socket, "root@lilly-guest", deadline(120_000))
    socket
  end

  defp command(socket, text) do
    marker = "SMOKE_" <> Base.encode16(:crypto.strong_rand_bytes(6))
    :ok = Dtach.write(socket, text <> " && printf '\\n#{marker}:OK\\n'\n")
    wait(socket, "\n#{marker}:OK\n", deadline(30_000))
  end

  defp wait(socket, marker, until, tail \\ "") do
    if System.monotonic_time(:millisecond) >= until,
      do: raise("Guest assertion timed out; terminal bytes withheld")

    case Dtach.read(socket, 1000) do
      {:ok, bytes} ->
        body = :binary.replace(tail <> bytes, "\r", "", [:global])

        if :binary.match(body, marker) != :nomatch do
          :ok
        else
          count = min(byte_size(body), byte_size(marker))
          wait(socket, marker, until, binary_part(body, byte_size(body) - count, count))
        end

      {:error, :timeout} ->
        wait(socket, marker, until, tail)

      _ ->
        raise "Guest console closed; terminal bytes withheld"
    end
  end

  defp await(fun, ms, label), do: poll(fun, deadline(ms), label)

  defp poll(fun, until, label) do
    if fun.() do
      :ok
    else
      if System.monotonic_time(:millisecond) >= until, do: raise("Timed out: #{label}")

      receive do
      after
        100 -> poll(fun, until, label)
      end
    end
  end

  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms

  defp uuid do
    <<a::32, b::16, _::4, c::12, _::2, d::14, e::48>> = :crypto.strong_rand_bytes(16)

    for {value, width} <- [{a, 8}, {b, 4}, {0x4000 + c, 4}, {0x8000 + d, 4}, {e, 12}], into: [] do
      value |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(width, "0")
    end
    |> Enum.join("-")
  end
end

Lilly.JailedSmoke.run(System.argv())
