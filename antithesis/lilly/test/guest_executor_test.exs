defmodule OverallsAntithesis.Lilly.GuestExecutorTest do
  use ExUnit.Case, async: false

  alias OverallsAntithesis.Lilly.{
    GuestBoot,
    GuestChannels,
    GuestExecutor,
    GuestTrustReceipt,
    IntegratedHealth
  }

  alias OverallsProtocol.Execution
  alias Lilly.Control.Config
  alias Lilly.Host.Pool

  @host "11111111-1111-4111-8111-111111111111"
  @pool "22222222-2222-4222-8222-222222222222"
  @placement "33333333-3333-4333-8333-333333333333"
  @vm "44444444-4444-4444-8444-444444444444"
  @owner "66666666-6666-4666-8666-666666666666"
  @image "sha256:" <> String.duplicate("a", 64)
  @boot_id "77777777-7777-4777-8777-777777777777"
  @storage %{
    backend: :zfs,
    zpool_guid: "10001",
    dataset_guid: "10002",
    dataset: "tank/lilly"
  }

  setup do
    root = Path.join(System.tmp_dir!(), "guest-executor-#{System.unique_integer([:positive])}")
    File.mkdir!(root)
    File.chmod!(root, 0o700)
    socket = "/tmp/kag-#{System.unique_integer([:positive])}.sock"
    previous = System.get_env("OVERALLS_ANTITHESIS_GUEST_SOCKET")
    System.put_env("OVERALLS_ANTITHESIS_GUEST_SOCKET", socket)

    on_exit(fn ->
      if previous,
        do: System.put_env("OVERALLS_ANTITHESIS_GUEST_SOCKET", previous),
        else: System.delete_env("OVERALLS_ANTITHESIS_GUEST_SOCKET")

      File.rm_rf!(root)
      File.rm(socket)
    end)

    {:ok, network} = Lilly.Network.Config.new(@host, "eth0", [], root)

    execution = %Lilly.VM.Config{
      state_dir: root,
      network: network,
      firecracker: "/bin/true",
      jailer: "/bin/true",
      unshare: "/bin/true",
      launch_guard: "/bin/true",
      boot_log_writer: "/bin/true"
    }

    config = %Config{
      client: nil,
      state_dir: root,
      execution: execution,
      cgroup_path: "/sys/fs/cgroup/lilly.slice",
      pools: [
        %Pool{
          id: @pool,
          path: root,
          filesystem_id: "zfs:10001:10002",
          storage: @storage,
          backend:
            if(System.get_env("ANTITHESIS_INTEGRATED_HOST") == "1", do: :zfs, else: :controlled)
        }
      ]
    }

    %{root: root, socket: socket, config: config}
  end

  test "exact image, process and guest readiness prove only emulated running and retained stop",
       ctx do
    command = command("provision", 1)
    stop_command = command("stop", 2)
    listener = listen(ctx.socket)

    server =
      Task.async(fn ->
        assert %{"operation" => "identity"} = request(listener, identity())

        assert %{"operation" => "reconcile", "placement_id" => @placement} =
                 launched =
                 request(listener, fn req -> observation(req, "running", false) end)

        assert %{"operation" => "readiness", "boot_challenge" => challenge} =
                 request(listener, fn req -> observation(req, "running", true) end)

        assert challenge == launched["boot_challenge"]
        assert %{"operation" => "identity"} = request(listener, identity())

        assert %{"operation" => "stop", "boot_challenge" => ^challenge} =
                 request(listener, fn req -> observation(req, "stopped", false) end)

        assert %{"operation" => "inventory"} =
                 request(listener, %{
                   "state" => "ok",
                   "placements" => [entry("stopped", false, true, 1)]
                 })
      end)

    assert {:ok, %{state: :running, guest_ready: true, disk_present: true}} =
             GuestExecutor.reconcile(ctx.config, command, %{})

    assert {:ok, boot} = GuestBoot.read(ctx.root, @placement)
    assert boot.state == :running
    assert boot.boot_challenge =~ ~r/\A[0-9a-f]{64}\z/

    assert {:ok, %{state: :stopped, disk_present: true, cleanup_complete: false}} =
             GuestExecutor.reconcile(ctx.config, stop_command, %{})

    assert {:ok, %{state: :stopped}} = GuestBoot.read(ctx.root, @placement)
    Task.await(server)
    :gen_tcp.close(listener)
  end

  test "image mismatch refuses before durable boot or runner mutation", ctx do
    command = command("provision", 1)
    listener = listen(ctx.socket)

    server =
      Task.async(fn ->
        assert %{"operation" => "identity"} =
                 request(listener, %{
                   identity()
                   | "image_id" => "sha256:" <> String.duplicate("b", 64)
                 })
      end)

    assert {:retry, :execution_unavailable} = GuestExecutor.reconcile(ctx.config, command, %{})
    assert {:ok, nil} = GuestBoot.read(ctx.root, @placement)
    Task.await(server)
    :gen_tcp.close(listener)
  end

  test "uncertain runner state does not turn a launch attempt into an outcome", ctx do
    command = command("provision", 1)
    listener = listen(ctx.socket)

    server =
      Task.async(fn ->
        request(listener, identity())
        request(listener, fn req -> observation(req, "uncertain", false) end)
      end)

    assert {:retry, :execution_unavailable} = GuestExecutor.reconcile(ctx.config, command, %{})
    assert {:ok, %{state: :launching}} = GuestBoot.read(ctx.root, @placement)
    Task.await(server)
    :gen_tcp.close(listener)
  end

  test "private services refuse a fresh guest launch before runner mutation", ctx do
    command = command("provision", 1)

    private_network = %{
      ctx.config.execution.network
      | private_services: true,
        host_id: "99999999-9999-4999-8999-999999999999"
    }

    config = %{ctx.config | execution: %{ctx.config.execution | network: private_network}}
    listener = listen(ctx.socket)

    server =
      Task.async(fn -> assert %{"operation" => "identity"} = request(listener, identity()) end)

    assert {:retry, :execution_unavailable} = GuestExecutor.reconcile(config, command, %{})
    assert {:ok, nil} = GuestBoot.read(ctx.root, @placement)
    Task.await(server)
    :gen_tcp.close(listener)
  end

  test "private services refuse a stopped guest restart before runner mutation", ctx do
    {:ok, boot} = GuestBoot.prepare(ctx.root, command("provision", 1))
    :ok = GuestBoot.mark(ctx.root, boot, :stopped)

    private_network = %{
      ctx.config.execution.network
      | private_services: true,
        host_id: "99999999-9999-4999-8999-999999999999"
    }

    config = %{ctx.config | execution: %{ctx.config.execution | network: private_network}}
    listener = listen(ctx.socket)

    server =
      Task.async(fn -> assert %{"operation" => "identity"} = request(listener, identity()) end)

    assert {:retry, :execution_unavailable} =
             GuestExecutor.reconcile(config, command("start", 2), %{})

    assert {:ok, %{generation: 1, state: :stopped}} = GuestBoot.read(ctx.root, @placement)
    Task.await(server)
    :gen_tcp.close(listener)
  end

  test "a pinned live guest can be re-observed while private services are unavailable", ctx do
    command = command("provision", 1)
    {:ok, boot} = GuestBoot.prepare(ctx.root, command)
    :ok = GuestBoot.mark(ctx.root, boot, :running)

    private_network = %{
      ctx.config.execution.network
      | private_services: true,
        host_id: "99999999-9999-4999-8999-999999999999"
    }

    config = %{ctx.config | execution: %{ctx.config.execution | network: private_network}}
    listener = listen(ctx.socket)

    server =
      Task.async(fn ->
        request(listener, identity())
        request(listener, fn req -> process_proof(req, "running") end)
        request(listener, fn req -> process_proof(req, "running") end)
        request(listener, fn req -> observation(req, "running", false) end)
        request(listener, fn req -> observation(req, "running", true) end)
      end)

    assert {:ok, %{state: :running, guest_ready: true}} =
             GuestExecutor.reconcile(config, command, %{})

    Task.await(server)
    :gen_tcp.close(listener)
  end

  test "startup inventory refuses untracked or uncertain emulator state", ctx do
    command = command("provision", 1)
    listener = listen(ctx.socket)

    server =
      Task.async(fn ->
        request(listener, %{"state" => "ok", "placements" => [entry("uncertain", false, true)]})
        request(listener, %{"state" => "ok", "placements" => [entry("running", true, true)]})
      end)

    assert {:error, :untracked_vm_units} = GuestExecutor.verify_units([command])
    assert :ok = GuestExecutor.verify_units([command])
    Task.await(server)
    :gen_tcp.close(listener)
  end

  test "terminal options refuse a ready guest without private trust roots and receipt", ctx do
    command = command("provision", 1)
    {:ok, boot} = GuestBoot.prepare(ctx.root, command)
    :ok = GuestBoot.mark(ctx.root, boot, :running)
    listener = listen(ctx.socket)
    socket_root = Path.join(ctx.root, "sockets")
    socket_dir = Path.join(socket_root, binary_part(@placement, 0, 8))
    File.mkdir_p!(socket_dir)
    vsock_path = Path.join(socket_dir, "v.sock")
    vsock = listen(vsock_path)
    previous = System.get_env("OVERALLS_ANTITHESIS_GUEST_SOCKET_ROOT")
    System.put_env("OVERALLS_ANTITHESIS_GUEST_SOCKET_ROOT", socket_root)

    on_exit(fn ->
      if previous,
        do: System.put_env("OVERALLS_ANTITHESIS_GUEST_SOCKET_ROOT", previous),
        else: System.delete_env("OVERALLS_ANTITHESIS_GUEST_SOCKET_ROOT")
    end)

    server =
      Task.async(fn ->
        request(listener, identity())
        request(listener, fn req -> observation(req, "running", true) end)
        request(listener, identity())
        request(listener, identity())
        request(listener, fn req -> observation(req, "running", true) end)
      end)

    assert {:ok, ^vsock_path} = GuestChannels.socket_path(boot)
    assert {:error, :terminal_unavailable} = GuestExecutor.terminal_options(ctx.config, command)

    assert {:error, :terminal_unavailable} =
             GuestExecutor.terminal_options(ctx.config, command("start", 2))

    :gen_tcp.close(vsock)
    File.rm!(vsock_path)
    assert {:error, :terminal_unavailable} = GuestChannels.socket_path(boot)
    assert {:error, :terminal_unavailable} = GuestExecutor.terminal_options(ctx.config, command)
    Task.await(server)
    :gen_tcp.close(listener)
  end

  test "public trust receipt is bound to the exact private boot and root digest", ctx do
    command = command("provision", 1)
    {:ok, boot} = GuestBoot.prepare(ctx.root, command)
    roots = ["public test root"]

    assert {:error, :trust_unconfirmed} = GuestTrustReceipt.read(ctx.root, boot, roots)

    assert :ok =
             GuestTrustReceipt.write(
               ctx.root,
               boot,
               roots,
               @boot_id,
               Lilly.VM.GuestTrust.digest(roots)
             )

    assert {:ok, @boot_id} = GuestTrustReceipt.read(ctx.root, boot, roots)
    assert {:error, :trust_unconfirmed} = GuestTrustReceipt.read(ctx.root, boot, ["other root"])

    assert {:error, :trust_unconfirmed} =
             GuestTrustReceipt.read(
               ctx.root,
               %{boot | boot_challenge: String.duplicate("a", 64)},
               roots
             )
  end

  test "public trust delivery precedes exact guest readiness and private terminal", ctx do
    command = command("provision", 1)
    roots = ["public test root"]

    config = %{ctx.config | execution: %{ctx.config.execution | guest_trust_roots: roots}}
    pid = :os.getpid() |> List.to_string() |> String.to_integer()
    {:ok, stat} = File.read("/proc/#{pid}/stat")

    start_ticks =
      stat
      |> String.split(") ")
      |> List.last()
      |> String.split()
      |> Enum.at(19)
      |> String.to_integer()

    socket_root = Path.join(ctx.root, "sockets")
    socket_dir = Path.join(socket_root, binary_part(@placement, 0, 8))
    File.mkdir_p!(socket_dir)
    vsock_path = Path.join(socket_dir, "v.sock")
    vsock = listen(vsock_path)
    previous = System.get_env("OVERALLS_ANTITHESIS_GUEST_SOCKET_ROOT")
    System.put_env("OVERALLS_ANTITHESIS_GUEST_SOCKET_ROOT", socket_root)

    on_exit(fn ->
      if previous,
        do: System.put_env("OVERALLS_ANTITHESIS_GUEST_SOCKET_ROOT", previous),
        else: System.delete_env("OVERALLS_ANTITHESIS_GUEST_SOCKET_ROOT")
    end)

    trust_server =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(vsock, 10_000)
        assert {:ok, "CONNECT 1030\n"} = :gen_tcp.recv(socket, 0, 10_000)
        :ok = :gen_tcp.send(socket, "OK 1030\n")
        :ok = :inet.setopts(socket, packet: 4)
        {:ok, body} = :gen_tcp.recv(socket, 0, 10_000)
        request = JSON.decode!(body)
        assert request["roots"] == roots

        receipt =
          Map.take(
            request,
            ~w(version placement_id execution_epoch boot_challenge nonce bundle_digest)
          )
          |> Map.merge(%{"state" => "installed", "boot_id" => @boot_id})

        :ok = :gen_tcp.send(socket, JSON.encode!(receipt))
        :gen_tcp.close(socket)
      end)

    listener = listen(ctx.socket)

    rpc_server =
      Task.async(fn ->
        request(listener, identity())

        request(listener, fn req ->
          observation(req, "running", false) |> Map.put("qemu_pid", pid)
        end)

        request(listener, fn req -> process_proof(req, "running", pid, start_ticks) end)
        request(listener, fn req -> process_proof(req, "running", pid, start_ticks) end)

        request(listener, fn req ->
          observation(req, "running", true) |> Map.put("qemu_pid", pid)
        end)

        request(listener, identity())

        request(listener, fn req ->
          observation(req, "running", true) |> Map.put("qemu_pid", pid)
        end)
      end)

    assert {:ok, %{state: :running, guest_ready: true}} =
             GuestExecutor.reconcile(config, command, %{})

    assert {:ok, boot} = GuestBoot.read(ctx.root, @placement)
    assert {:ok, @boot_id} = GuestTrustReceipt.read(ctx.root, boot, roots)
    assert {:ok, options} = GuestExecutor.terminal_options(config, command)
    assert options[:vsock_path] == vsock_path
    Task.await(trust_server)
    Task.await(rpc_server)
    :gen_tcp.close(vsock)
    :gen_tcp.close(listener)
  end

  test "positive exact QEMU exit stops the backend before a crashed outcome", ctx do
    command = command("provision", 1)
    listener = listen(ctx.socket)

    server =
      Task.async(fn ->
        request(listener, identity())
        request(listener, fn req -> observation(req, "running", false) end)
        request(listener, fn req -> observation(req, "running", true) end)
        request(listener, identity())

        assert %{"operation" => "process_proof"} =
                 request(listener, fn req -> process_proof(req, "qemu_exited") end)

        assert %{"operation" => "stop"} =
                 request(listener, fn req -> observation(req, "stopped", false) end)

        request(listener, %{
          "state" => "ok",
          "placements" => [entry("stopped", false, true, 1)]
        })
      end)

    assert {:ok, %{state: :running}} = GuestExecutor.reconcile(ctx.config, command, %{})

    assert {:ok, %{state: :failed, reason: :crashed, compute_empty: true, disk_present: true}} =
             GuestExecutor.reconcile(ctx.config, command, %{
               running_epoch: 1,
               running_generation: 1
             })

    assert {:ok, %{state: :stopped}} = GuestBoot.read(ctx.root, @placement)
    Task.await(server)
    :gen_tcp.close(listener)
  end

  test "uncertain or mismatched exit proof cannot become a crash outcome", ctx do
    command = command("provision", 1)
    {:ok, boot} = GuestBoot.prepare(ctx.root, command)
    :ok = GuestBoot.mark(ctx.root, boot, :running)
    listener = listen(ctx.socket)

    server =
      Task.async(fn ->
        request(listener, identity())

        request(listener, fn req ->
          process_proof(req, "qemu_exited") |> Map.put("generation", 2)
        end)

        request(listener, fn req -> observation(req, "degraded", false) end)
      end)

    assert {:retry, :execution_unavailable} =
             GuestExecutor.reconcile(ctx.config, command, %{
               running_epoch: 1,
               running_generation: 1
             })

    assert {:ok, %{state: :running}} = GuestBoot.read(ctx.root, @placement)
    Task.await(server)
    :gen_tcp.close(listener)
  end

  test "actual inner-kernel process and cgroup bind watcher and roster proof", ctx do
    command = command("provision", 1)
    {:ok, boot} = GuestBoot.prepare(ctx.root, command)
    :ok = GuestBoot.mark(ctx.root, boot, :running)
    pid = :os.getpid() |> List.to_string() |> String.to_integer()
    {:ok, stat} = File.read("/proc/#{pid}/stat")
    ticks = stat |> String.split(") ") |> List.last() |> String.split() |> Enum.at(19)
    start_ticks = String.to_integer(ticks)
    listener = listen(ctx.socket)

    server =
      Task.async(fn ->
        request(listener, identity())

        request(listener, fn req ->
          observation(req, "running", true) |> Map.put("qemu_pid", pid)
        end)

        request(listener, fn req -> process_proof(req, "running", pid, start_ticks) end)
        request(listener, identity())
        request(listener, fn req -> process_proof(req, "running", pid, start_ticks) end)
        request(listener, identity())
        request(listener, fn req -> process_proof(req, "qemu_exited", pid, start_ticks) end)
      end)

    assert {:ok, %{pid: ^pid, cgroup: cgroup}} =
             GuestExecutor.watch_target(ctx.config, command)

    assert String.starts_with?(cgroup, "/sys/fs/cgroup/")

    assert {:ok, %{pid: ^pid, cgroup: ^cgroup}} =
             GuestExecutor.boot_proof(ctx.config, command)

    assert {:error, :not_launched} = GuestExecutor.boot_proof(ctx.config, command)
    Task.await(server)
    :gen_tcp.close(listener)
  end

  test "integrated admission needs matching verified image, measured ZFS, and writable guest state",
       ctx do
    listener = listen(ctx.socket)
    pool = %{hd(ctx.config.pools) | backend: :zfs}
    config = %{ctx.config | pools: [pool]}

    report = %{
      capacity: %{
        "version" => 1,
        "cpu_headroom_millicores" => 1000,
        "memory_headroom_bytes" => 4_294_967_296,
        "interval_us" => 1_000_000,
        "covered" => %{}
      },
      inventory: %{"images" => [@image]},
      pools: [
        %{
          id: @pool,
          total_bytes: 8_589_934_592,
          free_bytes: 4_294_967_296,
          storage: Map.merge(@storage, %{used_bytes: 4_294_967_296, quota_bytes: nil}),
          allocations: %{}
        }
      ]
    }

    healthy = %{
      "state" => "ok",
      "image_id" => @image,
      "inventory_valid" => true,
      "state_writable" => true,
      "state_root" => "/pool/guest-emulator"
    }

    server =
      Task.async(fn ->
        assert %{"operation" => "health"} = request(listener, healthy)

        assert %{"operation" => "health"} =
                 request(listener, %{
                   healthy
                   | "image_id" => "sha256:" <> String.duplicate("b", 64)
                 })

        assert %{"operation" => "health"} =
                 request(listener, %{healthy | "state_writable" => false})

        assert %{"operation" => "health"} = request(listener, healthy)
      end)

    assert IntegratedHealth.ready?(config, report)
    refute IntegratedHealth.ready?(config, report)
    refute IntegratedHealth.ready?(config, report)
    refute IntegratedHealth.ready?(config, %{report | capacity: nil})

    refute IntegratedHealth.ready?(config, %{
             report
             | pools: [%{id: @pool, unavailable: true, storage: @storage}]
           })

    private_network = %{
      config.execution.network
      | private_services: true,
        host_id: "99999999-9999-4999-8999-999999999999"
    }

    private_config = %{config | execution: %{config.execution | network: private_network}}
    assert IntegratedHealth.ready?(private_config, report)

    Task.await(server)
    :gen_tcp.close(listener)
  end

  if System.get_env("ANTITHESIS_INTEGRATED_HOST") == "1" do
    test "local readiness binds a true sample to the exact authenticated delivered sequence" do
      now = DateTime.utc_now()

      state = %{
        phase: :connected,
        terminal_ready: true,
        last_error: nil,
        sample_error: nil,
        delivered_report_at: now,
        delivered_report_sequence: 1,
        latest: %{sequence: 2, inventory: %{"execution_ready" => true}},
        durable: %{},
        actors: %{}
      }

      refute Lilly.Control.Runtime.readiness(state, now)
      assert Lilly.Control.Runtime.readiness(%{state | delivered_report_sequence: 2}, now)

      refute Lilly.Control.Runtime.readiness(
               %{
                 state
                 | delivered_report_sequence: 2,
                   latest: %{sequence: 2, inventory: %{"execution_ready" => false}}
               },
               now
             )
    end
  end

  @spec listen(Path.t()) :: :gen_tcp.listen_socket()
  defp listen(path) do
    {:ok, listener} =
      :gen_tcp.listen(0, [:binary, active: false, packet: :line, ip: {:local, path}])

    listener
  end

  @spec request(:gen_tcp.listen_socket(), map() | (map() -> map())) :: map()
  defp request(listener, response) do
    {:ok, socket} = :gen_tcp.accept(listener, 10_000)
    {:ok, line} = :gen_tcp.recv(socket, 0, 10_000)
    {:ok, request} = JSON.decode(line)
    value = if is_function(response, 1), do: response.(request), else: response
    :ok = :gen_tcp.send(socket, JSON.encode!(value) <> "\n")
    :gen_tcp.close(socket)
    request
  end

  @spec identity() :: map()
  defp identity,
    do: %{
      "state" => "ok",
      "image_id" => @image,
      "minimum_disk_bytes" => 2_147_483_648,
      "memory_bytes" => 2_147_483_648,
      "vcpu" => 1,
      "workspace_source_version" => nil
    }

  @spec observation(map(), String.t(), boolean()) :: map()
  defp observation(request, state, ready) do
    running = state == "running"

    %{
      "state" => state,
      "placement_id" => request["placement_id"],
      "execution_epoch" => request["execution_epoch"],
      "generation" => request["generation"],
      "boot_id" => if(ready, do: @boot_id),
      "qemu_pid" => if(running, do: 101),
      "backend_pid" => if(running, do: 102),
      "ready" => ready,
      "qemu_rss_kib" => if(running, do: 100),
      "backend_rss_kib" => if(running, do: 20),
      "error" => nil
    }
  end

  @spec process_proof(map(), String.t(), pos_integer(), pos_integer()) :: map()
  defp process_proof(request, state, pid \\ 101, ticks \\ 1),
    do: %{
      "state" => state,
      "placement_id" => request["placement_id"],
      "execution_epoch" => request["execution_epoch"],
      "generation" => request["generation"],
      "qemu_pid" => pid,
      "qemu_start_ticks" => ticks,
      "backend_pid" => 102,
      "backend_start_ticks" => 11
    }

  @spec entry(String.t(), boolean(), boolean(), pos_integer() | nil) :: map()
  defp entry(state, live, overlay, generation \\ nil) do
    %{
      "placement_id" => @placement,
      "execution_epoch" => if(live or not is_nil(generation), do: 1),
      "generation" => if(live, do: 1, else: generation),
      "state" => state,
      "live" => live,
      "overlay_present" => overlay,
      "qemu_pid" => if(live, do: 101),
      "backend_pid" => if(live, do: 102)
    }
  end

  @spec command(String.t(), pos_integer()) :: Execution.command()
  defp command(kind, generation) do
    raw = %{
      "id" => "55555555-5555-4555-8555-555555555555",
      "vm_id" => @vm,
      "owner_id" => @owner,
      "placement_id" => @placement,
      "execution_epoch" => 1,
      "host_id" => @host,
      "pool_id" => @pool,
      "generation" => generation,
      "kind" => kind,
      "architecture" => "x86_64",
      "profile" => "customer",
      "vcpu" => 1,
      "memory_bytes" => 2_147_483_648,
      "disk_bytes" => 4_294_967_296,
      "image_id" => @image,
      "slot" => 2
    }

    {:ok, command} = OverallsProtocol.Execution.command(raw)
    command
  end
end
