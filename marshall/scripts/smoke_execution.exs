Code.require_file("../../lilly/scripts/zfs_fixture.exs", __DIR__)
# Destructive only to its own fresh fixture. Requires root KVM, systemd, ZFS,
# static pinned VMM tools, and the migrated test database. See lilly/README.md.
Code.require_file("browser_terminal_probe.exs", __DIR__)

defmodule Overalls.ExecutionSmoke do
  alias Lilly.Host.{Command, Lock, Ownership, Pool, PrivateFiles}
  alias Lilly.Control.{Config, Runtime, Store}
  alias Lilly.VM.{Disk, Driver, Executor, Unit}

  alias Marshall.Compute.{
    Credentials,
    Drains,
    Host,
    Images,
    Ledger,
    Operation,
    Reservation,
    StoragePool,
    VirtualMachine
  }

  @base "/var/lib/lilly"
  @script Path.expand(__ENV__.file)

  def run(["worker", encoded]) do
    Process.flag(:trap_exit, true)
    Logger.configure(level: :error)
    context = JSON.decode!(encoded)
    {:ok, %File.Stat{uid: 0}} = File.stat("/proc/self")

    if context["prepare"] do
      {:error, :enoent} = File.lstat(@base)
      {:ok, lock} = Lock.acquire("/run/lilly")

      {:ok, active} =
        Command.run(:systemctl, ["show", "lilly.slice", "--property=ActiveState", "--value"])

      :ok = PrivateFiles.directory(@base)

      fixture =
        Lilly.ZFSFixture.create(
          context["zfs_parent_dataset"],
          context["pool"],
          context["host_id"]
        )

      :ok =
        PrivateFiles.write(
          @base,
          "smoke.json",
          JSON.encode!(
            Map.merge(context, %{
              "slice_was_active" => active == "active\n",
              "zfs_fixture" => fixture
            })
          )
        )

      {:ok, _} = Command.run(:systemctl, ["start", "lilly.slice"])
      :ok = Ownership.verify_units([])
      Lock.release(lock)
    else
      {:ok, body} = PrivateFiles.read_secret(@base <> "/smoke.json")
      true = JSON.decode!(body)["host_id"] == context["host_id"]
    end

    {:ok, pool} = Pool.inspect_path(context["pool"])

    reply("ready", %{
      filesystem_id: pool.filesystem_id,
      storage: OverallsProtocol.Storage.encode(pool.storage),
      pid: System.pid()
    })

    worker_loop(context)
  end

  def run(args) do
    {options, [], []} =
      OptionParser.parse(args,
        strict: [
          guest: :string,
          zfs_parent_dataset: :string,
          firecracker: :string,
          jailer: :string,
          dtach: :string,
          unshare: :string,
          elixir: :string,
          host_tools: :string,
          egress: :string,
          browser_python: :string,
          browser_artifacts: :string
        ]
      )

    config = Application.fetch_env!(:marshall, Marshall.Repo)

    Application.put_env(
      :marshall,
      Marshall.Repo,
      Keyword.merge(config, pool: DBConnection.ConnectionPool, pool_size: 8)
    )

    endpoint = Application.fetch_env!(:marshall, MarshallWeb.Endpoint)

    Application.put_env(
      :marshall,
      MarshallWeb.Endpoint,
      Keyword.merge(endpoint, check_origin: ["//127.0.0.1"], url: [host: "127.0.0.1"])
    )

    {:ok, _} = Application.ensure_all_started(:marshall)
    Logger.configure(level: :warning)
    token = Base.encode16(:crypto.strong_rand_bytes(6), case: :lower)
    {:ok, machine} = Lilly.Host.Identity.read()

    host =
      Ledger.create!(Host, :enroll, %{
        name: "execution-smoke-" <> token,
        architecture: :x86_64,
        machine_id: machine,
        overhead_cores: 0,
        overhead_memory_bytes: 0
      })

    host_id = host.id
    Process.put(:host, host)

    context = %{
      "prepare" => true,
      "zfs_parent_dataset" => Keyword.fetch!(options, :zfs_parent_dataset),
      "host_id" => host_id,
      "pool" => "/tmp/lx-" <> token,
      "token" => token
    }

    port = worker(options, context)
    Process.put(:worker, port)
    Process.put(:context, context)
    Process.put(:options, options)
    Process.put(:vms, [])

    try do
      ready = response(port, "ready")

      {:ok, storage} = OverallsProtocol.Storage.identity(ready["storage"])

      pool =
        Ledger.create!(StoragePool, :enroll, %{
          host_id: host.id,
          name: "guests",
          filesystem_id: ready["filesystem_id"],
          backend: :zfs,
          zpool_guid: storage.zpool_guid,
          dataset_guid: storage.dataset_guid,
          dataset: storage.dataset,
          overhead_bytes: 0
        })

      {:ok, image} =
        Images.register(
          File.read!(Path.join(Keyword.fetch!(options, :guest), "manifest.json"))
          |> JSON.decode!(),
          "execution-smoke-image"
        )

      Process.put(:image_id, image.id)
      user = Ash.Seed.seed!(Marshall.Accounts.User, %{email: "execution-#{token}@example.test"})
      Process.put(:user, user)

      {:ok, server} =
        Bandit.start_link(
          plug: MarshallWeb.Endpoint,
          scheme: :https,
          ip: {127, 0, 0, 1},
          port: 0,
          startup_log: false,
          certfile: Path.expand("../test/fixtures/tls/localhost.pem", __DIR__),
          keyfile: Path.expand("../test/fixtures/tls/localhost.key", __DIR__)
        )

      {:ok, {_, number}} = ThousandIsland.listener_info(server)
      {:ok, credential} = Credentials.rotate(host.id, 3600)

      runtime = %{
        "version" => 3,
        "host_id" => host.id,
        "control_plane" => "https://127.0.0.1:#{number}",
        "credential" => credential.token,
        "state_dir" => @base <> "/runtime",
        "cacertfile" => @base <> "/ca.pem",
        "cgroup_path" => "/sys/fs/cgroup/lilly.slice",
        "images" => [Keyword.fetch!(options, :guest)],
        "pools" => [
          %{
            "id" => pool.id,
            "path" => context["pool"],
            "filesystem_id" => pool.filesystem_id,
            "storage" => ready["storage"]
          }
        ],
        "execution" =>
          Map.merge(
            Map.new(
              for key <- [:firecracker, :jailer, :dtach, :unshare],
                  do: {Atom.to_string(key), Keyword.fetch!(options, key)}
            ),
            %{
              "state_dir" => @base <> "/vms",
              "network_state_dir" => @base <> "/network",
              "egress_interface" => Keyword.fetch!(options, :egress),
              "protected_cidrs" => []
            }
          )
      }

      rpc("configure", %{
        config: runtime,
        ca: File.read!(Path.expand("../test/fixtures/tls/ca.pem", __DIR__))
      })

      fresh(host.id)
      Ledger.update!(host, :configure, %{enabled: true})
      true = rpc("competing_owner")["rejected"]

      phase(
        "Authenticated v3 runtime owns the host, rejects a competing state directory and reports executable capacity."
      )

      vms =
        for profile <- [:customer, :standard, :oss] do
          {:ok, vm} =
            Marshall.Compute.provision(
              %{
                idempotency_key: Lilly.UUID.generate(),
                architecture: :x86_64,
                image_id: image.id,
                profile: profile,
                vcpu: 1,
                memory_bytes: 536_870_912,
                disk_bytes: 2_147_483_648
              },
              actor: user
            )

          Process.put(:vms, [vm | Process.get(:vms)])
          vm
        end

      for vm <- vms, do: observed(vm.id, :running)

      phase(
        "Three profile VMs reached physical Running through the real HTTPS command/outcome loop."
      )

      for vm <- vms, do: rpc("console", %{vm_id: vm.id, action: "internet"}, 150_000)
      first = hd(vms)

      Overalls.BrowserTerminalProbe.run(
        options,
        "https://127.0.0.1:#{number}",
        first,
        user,
        Process.get(:terminal_member)
      )

      rpc("console", %{vm_id: first.id, action: "write"}, 150_000)
      before = Map.new(vms, fn item -> {item.id, rpc("inspect", %{vm_id: item.id})["pid"]} end)
      true = Enum.all?(Map.values(before), &is_integer/1)
      old = Process.get(:worker)
      rpc("crash_runtime")
      await_exit(old)
      restarted = worker(options, %{context | "prepare" => false})
      Process.put(:worker, restarted)
      response(restarted, "ready")
      rpc("start")
      fresh(host.id)
      for item <- vms, do: true = before[item.id] == rpc("inspect", %{vm_id: item.id})["pid"]
      rpc("console", %{vm_id: first.id, action: "read"}, 150_000)

      phase(
        "Hard-killing Lilly preserves the VMM PID, console and disk; the new runtime reconciles them."
      )

      drain_id = Ash.UUID.generate()
      {:ok, %{status: "draining"}} = Drains.request(host.id, drain_id, "kvm-smoke")
      %{success: 1, failure: 0} = Oban.drain_queue(queue: :maintenance)

      for item <- vms do
        observed(item.id, :stopped)
        assert_reservation(item.id, false, true)
        true = rpc("inspect", %{vm_id: item.id})["disk_present"]
      end

      await(
        fn -> match?({:ok, %{status: "drained"}}, Drains.status(drain_id)) end,
        15_000,
        :drained
      )

      {:error, :retained_host_resources} = Drains.retire(drain_id)
      rpc("stop")
      true = rpc("stop_contention", %{vm_id: first.id})["deferred"]
      rpc("start")
      fresh(host.id)
      {:ok, %{status: "resumed"}} = Drains.resume(drain_id)

      for item <- vms do
        :stopped = vm(item.id).desired_state
        assert_reservation(item.id, false, true)
        lifecycle(item.id, :start, user)
        observed(item.id, :running)
      end

      rpc("console", %{vm_id: first.id, action: "read"}, 150_000)

      phase(
        "Host drain confirms all three guests stopped, retains disks, and resume permits explicit starts with persistent data."
      )

      for attempt <- 1..4 do
        previous = vm(first.id).generation
        rpc("crash_vm", %{vm_id: first.id})

        if attempt <= 3 do
          await(
            fn ->
              item = vm(first.id)
              item.generation > previous and item.observed_state == :running
            end,
            90_000,
            :crash_restart
          )

          true = vm(first.id).generation == previous + 1
          true = length(vm(first.id).crash_restart_times) == attempt
          assert_reservation(first.id, true, true)
        else
          observed(first.id, :failed)
          true = vm(first.id).generation == previous
          true = length(vm(first.id).crash_restart_times) == 3
          assert_reservation(first.id, false, true)
        end
      end

      phase(
        "Exactly three automatic crash restarts are admitted; the fourth crash releases compute and retains disk."
      )

      fresh(host.id)
      lifecycle(first.id, :start, user)
      observed(first.id, :running)
      rpc("console", %{vm_id: first.id, action: "read"}, 150_000)
      {:ok, :ok} = Credentials.revoke(host.id)
      await(fn -> rpc("status")["phase"] == "fenced" end, 15_000, :credential_fence)
      true = is_integer(rpc("inspect", %{vm_id: first.id})["pid"])
      assert_reservation(first.id, true, true)
      {:ok, replacement} = Credentials.rotate(host.id, 3600)
      rpc("stop")

      rpc("configure", %{
        config: %{runtime | "credential" => replacement.token},
        ca: File.read!(Path.expand("../test/fixtures/tls/ca.pem", __DIR__))
      })

      fresh(host.id)
      for vm <- vms, do: lifecycle(vm.id, :delete, user)

      for item <- vms do
        await(fn -> vm(item.id).archived_at != nil end, 90_000, :archive)
        assert_reservation(item.id, false, false)
      end

      await(
        fn ->
          status = rpc("status")
          status["stored_vm_count"] == 0 and status["vm_actor_count"] == 0
        end,
        15_000,
        :actor_retirement
      )

      phase(
        "Revocation fences execution; rotated credentials recover it. Confirmed deletion archives all VMs and retires actors."
      )

      fresh(host.id)
      retirement_id = Ash.UUID.generate()
      {:ok, _} = Drains.request(host.id, retirement_id, "kvm-retirement")

      await(
        fn ->
          [pool] = Ledger.read!(StoragePool, id: pool.id)

          pool.allocations == %{} and
            Marshall.Compute.HostLiveness.capacity_fresh?(pool.reported_at, Ledger.now())
        end,
        15_000,
        :empty_pool_report
      )

      %{success: 1, failure: 0} = Oban.drain_queue(queue: :maintenance)

      await(
        fn -> match?({:ok, %{status: "drained"}}, Drains.status(retirement_id)) end,
        15_000,
        :retirement_ready
      )

      {:ok, %{status: "retired"}} = Drains.retire(retirement_id)
      await(fn -> rpc("status")["phase"] == "fenced" end, 15_000, :retirement_fence)

      phase(
        "Retirement verifies empty host allocations, revokes credentials and fences the provisioner."
      )
    after
      try do
        cleanup()
      rescue
        error ->
          IO.puts(
            "Cleanup incomplete; retain fixture state and database rows for repair. " <>
              diagnostic(error, __STACKTRACE__)
          )
      end
    end
  end

  defp worker_loop(context) do
    case IO.read(:stdio, :line) do
      :eof ->
        :ok

      line ->
        request = JSON.decode!(line)

        try do
          value = dispatch(request["operation"], request, context)
          reply(request["request"], value)
        rescue
          error -> reply(request["request"], %{error: diagnostic(error, __STACKTRACE__)})
        catch
          kind, _ -> reply(request["request"], %{error: Atom.to_string(kind)})
        end

        worker_loop(context)
    end
  end

  defp dispatch("configure", request, _context) do
    :ok = PrivateFiles.write(@base, "ca.pem", request["ca"])
    :ok = PrivateFiles.write(@base, "config.json", JSON.encode!(request["config"]))
    dispatch("start", %{}, %{})
  end

  defp dispatch("start", _, _) do
    {:ok, config} = Config.load(@base <> "/config.json")
    Process.put(:config, config)
    {:ok, _} = Application.ensure_all_started(:req)
    {:ok, runtime} = Runtime.start_link(config: config, name: Runtime)
    Process.put(:runtime, runtime)
    %{started: true}
  end

  defp dispatch("competing_owner", _, _) do
    config = Process.get(:config)
    result = Runtime.start_link(config: %{config | state_dir: @base <> "/competing"})
    %{rejected: result == {:error, :host_already_owned}}
  end

  defp dispatch("status", _, _), do: Runtime.status()

  defp dispatch("crash_console", _, _) do
    state = :sys.get_state(Runtime)
    true = is_pid(state.console)
    Process.exit(state.console, :kill)
    %{crashed: true}
  end

  defp dispatch("stop", _, _) do
    if pid = Process.delete(:runtime), do: GenServer.stop(pid, :normal, 15_000)
    %{stopped: true}
  end

  defp dispatch("stop_contention", request, _) do
    config = Process.get(:config)
    {:ok, host_lock} = Lock.acquire("/run/lilly")
    {:ok, state_lock} = Lock.acquire(config.state_dir)
    {:ok, store} = Store.open(config.state_dir, config.client.host_id, 3)
    {:ok, commands} = Store.all(store)
    [%{kind: :stop} = command] = Enum.filter(commands, &(&1.vm_id == request["vm_id"]))

    {:ok, network_lock} =
      Lock.acquire(Path.join(config.execution.network.state_dir, "network-lock"))

    try do
      {:retry, :network_unavailable} =
        Executor.reconcile(config, command, %{running_epoch: 0, running_generation: 0})

      %{deferred: true}
    after
      Lock.release(network_lock)
      Lock.release(state_lock)
      Lock.release(host_lock)
    end
  end

  defp dispatch("crash_runtime", request, _) do
    reply(request["request"], %{crashing: true})
    System.cmd("/usr/bin/kill", ["-KILL", System.pid()])
    System.halt(1)
  end

  defp dispatch("cleanup", _, context) do
    dispatch("stop", %{}, context)
    {:ok, lock} = Lock.acquire("/run/lilly")
    {:ok, metadata} = PrivateFiles.read_secret(@base <> "/smoke.json")
    metadata = JSON.decode!(metadata)
    true = metadata["host_id"] == context["host_id"]

    if config = Process.get(:config) do
      {:ok, store} = Store.open(config.state_dir, config.client.host_id, 3)
      {:ok, commands} = Store.all(store)

      for command <- commands do
        {:ok, spec} = Executor.specification(command)
        pool = Enum.find(config.pools, &(&1.id == command.pool_id))
        :ok = Driver.delete(config.execution, pool, spec)
      end

      :ok = Lilly.Network.destroy(config.execution.network)
    end

    :ok = Ownership.verify_units([])
    if not metadata["slice_was_active"], do: Command.run(:systemctl, ["stop", "lilly.slice"])
    :ok = Lilly.ZFSFixture.destroy(metadata["zfs_fixture"])
    {:ok, _} = File.rm_rf(@base)
    Lock.release(lock)
    %{cleaned: true}
  end

  defp dispatch(operation, request, context)
       when operation in ["inspect", "console", "crash_vm"] do
    config = Process.get(:config)
    {:ok, store} = Store.open(config.state_dir, config.client.host_id, 3)
    {:ok, commands} = Store.all(store)
    [command] = Enum.filter(commands, &(&1.vm_id == request["vm_id"]))
    {:ok, spec} = Executor.specification(command)
    pool = Enum.find(config.pools, &(&1.id == command.pool_id))

    case operation do
      "inspect" ->
        pids =
          Path.wildcard(Unit.cgroup(spec) <> "/**/cgroup.procs") ++
            [Unit.cgroup(spec) <> "/cgroup.procs"]

        pid =
          pids
          |> Enum.flat_map(fn path ->
            case File.read(path) do
              {:ok, body} -> String.split(body)
              _ -> []
            end
          end)
          |> Enum.uniq()
          |> Enum.find(fn pid -> File.read("/proc/#{pid}/comm") == {:ok, "firecracker\n"} end)

        %{
          pid: if(pid, do: String.to_integer(pid)),
          disk_present: File.regular?(Disk.path(pool, spec))
        }

      "crash_vm" ->
        # Killing the service's main supervisor causes an unexpected VM exit.
        # systemd 255 on this host rejects auxiliary-process signalling in the
        # jailer's nested cgroup; target the tracked main PID through systemd.
        {:ok, _} =
          Command.run(
            :systemctl,
            ["kill", "--kill-whom=main", "--signal=SIGKILL", Unit.name(spec)],
            10_000
          )

        %{crashed: true}

      "console" ->
        {:ok, socket} = Lilly.Console.Dtach.connect(Unit.console(config.execution, spec))

        try do
          :ok = Lilly.Console.Dtach.write(socket, "\n")
          console_wait(socket, "root@lilly-guest", deadline(120_000))

          text =
            case request["action"] do
              "internet" -> "curl --silent --fail --max-time 20 https://example.com/ -o /dev/null"
              "write" -> "printf '#{context["token"]}' >/root/lilly-e2e-marker; sync"
              "read" -> "test \"$(cat /root/lilly-e2e-marker)\" = '#{context["token"]}'"
            end

          marker = "EXEC_" <> Base.encode16(:crypto.strong_rand_bytes(6))
          :ok = Lilly.Console.Dtach.write(socket, text <> " && printf '\\n#{marker}:OK\\n'\n")
          console_wait(socket, "\n#{marker}:OK\n", deadline(30_000))
        after
          Lilly.Console.Dtach.close(socket)
        end

        %{verified: true}
    end
  end

  defp console_wait(socket, marker, until, tail \\ "") do
    if deadline(0) >= until, do: raise("Console assertion timed out; bytes withheld")

    case Lilly.Console.Dtach.read(socket, 1000) do
      {:ok, bytes} ->
        body = :binary.replace(tail <> bytes, "\r", "", [:global])

        if :binary.match(body, marker) == :nomatch do
          count = min(byte_size(body), byte_size(marker))
          console_wait(socket, marker, until, binary_part(body, byte_size(body) - count, count))
        end

      {:error, :timeout} ->
        console_wait(socket, marker, until, tail)

      _ ->
        raise("Console closed; bytes withheld")
    end
  end

  defp worker(options, context) do
    paths = Path.wildcard(Path.expand("../_build/test/lib/*/ebin", __DIR__))

    Port.open({:spawn_executable, "/usr/bin/sudo"}, [
      :binary,
      :exit_status,
      :stderr_to_stdout,
      args:
        [
          "-n",
          "env",
          "PATH=" <> Keyword.fetch!(options, :host_tools) <> "/bin:/usr/bin:/usr/sbin:/bin:/sbin",
          Keyword.fetch!(options, :elixir),
          "--erl",
          "+S 4:4"
        ] ++ Enum.flat_map(paths, &["-pa", &1]) ++ [@script, "worker", JSON.encode!(context)]
    ])
  end

  defp rpc(operation, payload \\ %{}, timeout \\ 20_000) do
    id = Lilly.UUID.generate()
    port = Process.get(:worker)

    if Port.info(port) == nil, do: raise("Root worker is not running")

    true =
      Port.command(
        port,
        JSON.encode!(Map.merge(payload, %{operation: operation, request: id})) <> "\n"
      )

    response(port, id, deadline(timeout))
  end

  defp response(port, id, until \\ deadline(30_000)) do
    key = {:output, port}
    buffer = Process.get(key, "")

    case :binary.split(buffer, "\n") do
      [line, rest] ->
        Process.put(key, rest)

        case JSON.decode(line) do
          {:ok, %{"request" => ^id, "value" => %{"error" => error}}} ->
            raise("Worker assertion #{id} failed: #{error}; payload withheld")

          {:ok, %{"request" => ^id, "value" => value}} ->
            value

          _ ->
            response(port, id, until)
        end

      _ ->
        receive do
          {^port, {:data, bytes}} ->
            if byte_size(buffer) + byte_size(bytes) > 1_048_576, do: raise("Worker output limit")
            Process.put(key, buffer <> bytes)
            response(port, id, until)

          {^port, {:exit_status, code}} ->
            raise("Root worker exited #{code}; output withheld")
        after
          max(0, until - deadline(0)) -> raise("Root worker response timed out")
        end
    end
  end

  defp diagnostic(error, stack) do
    locations = Enum.map(stack, fn {m, f, _args, info} -> "#{inspect(m)}.#{f}:#{info[:line]}" end)

    term =
      case error do
        %MatchError{term: {:error, reason}} when is_atom(reason) -> Atom.to_string(reason)
        %RuntimeError{message: "Injected signal failed" <> _ = message} -> message
        _ -> "payload withheld"
      end

    Enum.join([inspect(error.__struct__), term | locations], "; ")
  end

  defp reply(id, value), do: IO.puts(JSON.encode!(%{request: id, value: value}))

  defp await_exit(port) do
    receive do
      {^port, {:exit_status, _}} -> :ok
      {^port, {:data, _}} -> await_exit(port)
    after
      10_000 -> raise("Runtime process did not exit")
    end
  end

  defp vm(id), do: hd(Ledger.history!(VirtualMachine, id: id))
  defp observed(id, state), do: await(fn -> vm(id).observed_state == state end, 120_000, state)

  defp fresh(id),
    do:
      await(
        fn ->
          [host] = Ledger.read!(Host, id: id)

          rpc("status")["phase"] == "connected" and
            host.inventory["execution_ready"] == true and
            host.inventory["terminal_protocol"] == 2 and
            Marshall.Compute.HostLiveness.capacity_fresh?(host.reported_at, Ledger.now())
        end,
        20_000,
        :fresh_capacity
      )

  defp lifecycle(id, kind, user) do
    {:ok, operation} =
      Marshall.Compute.lifecycle(%{vm_id: id, kind: kind, idempotency_key: Lilly.UUID.generate()},
        actor: user
      )

    operation
  end

  defp assert_reservation(id, compute, disk) do
    [reservation] = Ledger.read!(Reservation, vm_id: id)
    true = reservation.compute_held == compute and reservation.disk_held == disk
  end

  defp deadline(ms), do: System.monotonic_time(:millisecond) + ms
  defp await(fun, ms, label), do: poll(fun, deadline(ms), label)

  defp poll(fun, until, label) do
    if not fun.() do
      if deadline(0) >= until do
        for item <- Process.get(:vms, []) do
          current = vm(item.id)

          IO.puts(
            JSON.encode!(
              Map.take(current, [
                :id,
                :generation,
                :observed_state,
                :failure_reason,
                :outcome_sequence
              ])
            )
          )
        end

        IO.puts(JSON.encode!(rpc("status")))
        raise("Timed out: #{label}")
      end

      receive do
      after
        100 -> poll(fun, until, label)
      end
    end
  end

  defp phase(text), do: IO.puts(text)

  defp cleanup do
    # Physical proof first; on failure leave durable state and the DB fixture for repair.
    rpc("cleanup", %{}, 180_000)
    Port.close(Process.get(:worker))

    if host = Process.get(:host) do
      ids = Enum.map(Process.get(:vms, []), &Ecto.UUID.dump!(&1.id))

      query = fn sql, params ->
        Ecto.Adapters.SQL.query!(Marshall.Repo, sql, params, log: false)
      end

      host_id = Ecto.UUID.dump!(host.id)

      for item <- Process.get(:vms, []), operation <- Ledger.read!(Operation, vm_id: item.id) do
        query.("DELETE FROM oban_jobs WHERE args->'primary_key'->>'id' = $1", [operation.id])
      end

      for {table, field} <- [
            {"terminal_sessions", "vm_id"},
            {"access_grants", "vm_id"}
          ] do
        query.(
          "DELETE FROM #{table}_versions WHERE version_source_id IN (SELECT id FROM #{table} WHERE #{field} = ANY($1))",
          [ids]
        )
      end

      query.(
        "DELETE FROM terminal_tickets WHERE session_id IN (SELECT id FROM terminal_sessions WHERE vm_id = ANY($1))",
        [ids]
      )

      for {table, field} <- [
            {"terminal_events", "vm_id"},
            {"terminal_sessions", "vm_id"},
            {"access_changes", "vm_id"},
            {"access_grants", "vm_id"},
            {"compute_physical_outcomes", "vm_id"},
            {"compute_operations", "vm_id"},
            {"compute_reservations", "vm_id"},
            {"compute_network_addresses", "vm_id"},
            {"compute_virtual_machines_versions", "version_source_id"},
            {"compute_virtual_machines", "id"}
          ] do
        if table == "compute_virtual_machines" do
          query.(
            """
            WITH removed AS (
              DELETE FROM compute_workload_placements WHERE vm_id = ANY($1) RETURNING vm_id
            ) DELETE FROM compute_virtual_machines WHERE id IN (SELECT vm_id FROM removed)
            """,
            [ids]
          )
        else
          query.("DELETE FROM #{table} WHERE #{field} = ANY($1)", [ids])
        end
      end

      query.(
        "DELETE FROM compute_host_credentials_versions WHERE version_source_id IN (SELECT id FROM compute_host_credentials WHERE host_id = $1)",
        [host_id]
      )

      for table <- [
            "compute_storage_pools",
            "compute_host_sessions",
            "compute_host_credentials"
          ] do
        query.("DELETE FROM #{table} WHERE host_id = $1", [host_id])
      end

      query.(
        "DELETE FROM oban_jobs WHERE args->'primary_key'->>'id' IN (SELECT id::text FROM compute_host_drains WHERE host_id = $1)",
        [host_id]
      )

      query.(
        "DELETE FROM compute_host_drains_versions WHERE version_source_id IN (SELECT id FROM compute_host_drains WHERE host_id = $1)",
        [host_id]
      )

      query.("DELETE FROM compute_host_drains WHERE host_id = $1", [host_id])
      query.("DELETE FROM compute_hosts WHERE id = $1", [host_id])

      for user <- [Process.get(:terminal_member), Process.get(:user)], user != nil do
        query.("DELETE FROM tokens WHERE subject = $1", ["user?id=" <> user.id])
        query.("DELETE FROM users WHERE id = $1", [Ecto.UUID.dump!(user.id)])
      end
    end

    if image = Process.get(:image_id) do
      for table <- ["compute_images_versions", "compute_images"] do
        field = if table == "compute_images", do: "id", else: "version_source_id"

        Ecto.Adapters.SQL.query!(
          Marshall.Repo,
          "DELETE FROM #{table} WHERE #{field} = $1 AND NOT EXISTS (SELECT 1 FROM compute_virtual_machines WHERE image_id = $1)",
          [image],
          log: false
        )
      end
    end

    phase("Fixture VMs, network, disks and database records cleaned; prior slice state restored.")
  end
end

Overalls.ExecutionSmoke.run(System.argv())
