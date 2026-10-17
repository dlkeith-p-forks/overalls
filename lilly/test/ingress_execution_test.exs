defmodule Lilly.IngressExecutionTest do
  use ExUnit.Case, async: true
  alias Lilly.Control.{Runtime, Store}
  alias Lilly.Ingress.{Backend, Guardian, Server}
  alias Lilly.VM.Actor
  alias Lilly.Execution
  alias OverallsProtocol.IngressConnect, as: Wire
  @moduletag :tmp_dir
  @id "11111111-1111-4111-8111-111111111111"

  defmodule Executor do
    def reconcile(_, _, _),
      do:
        {:ok,
         %{
           state: :running,
           compute_empty: false,
           disk_present: true,
           cleanup_complete: false,
           reason: :none
         }}

    def open_ingress(port, %{profile: :inception}, %{service: service})
        when service in [:control_https, :porsche_ssh, :audi_https, :audi_ssh],
        do: :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 500)

    def open_ingress(port, _, %{service: :ssh, port: 22}),
      do: :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 500)
  end

  test "customer actor allows private SSH binding but rejects web", c do
    assert {:ok, actor, _} = Runtime.ingress_authority(c.view, c.binding)
    assert actor == c.actor
    assert {:ok, _} = Runtime.private_binding(c.view, "10.10.0.2")

    for port <- [22, 80, 443, 3000, 9999, 65535] do
      assert {:error, :ingress_unavailable} =
               Runtime.ingress_authority(c.view, %{c.binding | service: :web, port: port})
    end
  end

  @tag profile: :standard
  test "eligible live actor retains private service identity", c do
    assert {:ok, _} = Runtime.private_binding(c.view, "10.20.0.2")
  end

  setup %{tmp_dir: directory} = context do
    File.chmod!(directory, 0o700)
    {:ok, store} = Store.open(directory, @id, 3)

    command = %{
      id: Lilly.UUID.generate(),
      vm_id: @id,
      owner_id: "0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f",
      placement_id: @id,
      execution_epoch: 1,
      host_id: @id,
      pool_id: @id,
      image_id: "sha256:" <> String.duplicate("a", 64),
      slot: 2,
      generation: 1,
      kind: :provision,
      architecture: :x86_64,
      profile: Map.get(context, :profile, :customer),
      vcpu: 1,
      memory_bytes: 536_870_912,
      disk_bytes: 2_147_483_648
    }

    {:ok, :stored} = Store.accept(store, command)
    # This test process plays the Runtime: the single writer of the connected
    # runtime row and the durable intent row in its own isolated view.
    view = :"ingress_view_#{System.unique_integer([:positive])}"
    start_supervised!({OverallsProtocol.View, name: view})
    :ok = Execution.runtime_connected(view)
    :ok = Execution.intent(view, command)
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(listener)
    on_exit(fn -> :gen_tcp.close(listener) end)

    actor =
      start_supervised!(
        {Actor,
         store: store, placement_id: @id, owner: self(), executor: {Executor, port}, view: view}
      )

    Actor.reconcile(actor)
    assert_receive {:vm_actor_outcome, @id, ^actor, %{state: :running}}, 2000

    binding = %{
      host_id: @id,
      vm_id: @id,
      placement_id: @id,
      session_id: @id,
      execution_epoch: 1,
      generation: 1,
      service: :ssh,
      port: 22,
      label: OverallsProtocol.IngressName.label("vm", @id)
    }

    %{
      store: store,
      command: command,
      actor: actor,
      binding: binding,
      view: view,
      resolver: {Runtime, view},
      listener: listener
    }
  end

  test "ordinary running actors reject every nested service before executor access", ctx do
    for service <- [:control_https, :porsche_ssh, :audi_https, :audi_ssh] do
      {_, port} = OverallsProtocol.InceptionName.destination(service)
      binding = Map.merge(ctx.binding, %{service: service, port: port, environment_generation: 1})
      assert Wire.valid?(binding)
      assert {:error, :ingress_unavailable} = Runtime.ingress_authority(ctx.view, binding)
    end
  end

  # These are local socket/actor checks with a loopback executor, not native
  # guest routing acceptance.
  for {profile, service} <- [
        customer: :ssh,
        inception: :control_https,
        inception: :porsche_ssh,
        inception: :audi_https,
        inception: :audi_ssh
      ] do
    @tag profile: profile
    @tag nested_service: service
    test "durable supersession closes an actual #{service} connector stream", ctx do
      binding =
        if ctx.nested_service == :ssh do
          ctx.binding
        else
          {_, port} = OverallsProtocol.InceptionName.destination(ctx.nested_service)

          Map.merge(ctx.binding, %{
            service: ctx.nested_service,
            port: port,
            environment_generation: 1
          })
        end

      directory = Path.join(System.tmp_dir!(), "lgi-" <> Lilly.UUID.generate())
      File.mkdir!(directory)
      File.chmod!(directory, 0o700)
      on_exit(fn -> File.rm_rf!(directory) end)
      path = Path.join(directory, "ingress.sock")
      {:ok, %{uid: uid}} = File.stat(directory)

      start_supervised!(
        {Server, path: path, audi_uid: uid, host_id: @id, backend: {Backend, ctx.resolver}}
      )

      {:ok, client} = :gen_tcp.connect({:local, path}, 0, [:binary, active: false, packet: 4])
      {:ok, request} = Wire.encode(binding)
      :gen_tcp.send(client, request)
      assert {:ok, ready} = :gen_tcp.recv(client, 0, 2000)
      assert Wire.ready?(ready)
      {:ok, guest} = :gen_tcp.accept(ctx.listener, 1000)
      :inet.setopts(client, packet: 0)
      :gen_tcp.send(client, "ssh stream")
      assert {:ok, "ssh stream"} = :gen_tcp.recv(guest, 10, 1000)
      stop = %{ctx.command | id: Lilly.UUID.generate(), generation: 2, kind: :stop}
      {:ok, :stored} = Store.accept(ctx.store, stop)
      :ok = Execution.intent(ctx.view, stop)
      assert {:error, :closed} = :gen_tcp.recv(client, 0, 1500)
      assert {:error, :closed} = :gen_tcp.recv(guest, 0, 1000)
      # The ingress stream does not own or terminate the VM actor.
      assert Process.alive?(ctx.actor)
    end
  end

  test "successful probes renew but suspended guardians cannot outlive their timer", ctx do
    assert {:ok, guardian, _} = Guardian.start(ctx.resolver, ctx.binding)
    ref = Process.monitor(guardian)
    refute_receive {:DOWN, ^ref, :process, ^guardian, _}, 1800
    :erlang.suspend_process(guardian)
    assert_receive {:DOWN, ^ref, :process, ^guardian, :killed}, 1600
    assert Process.alive?(ctx.actor)
  end

  # Slowness is not evidence of loss (ADR-0140): an unresponsive actor keeps
  # its proof until the running-observation backstop lapses, then the guardian
  # dies within its own watchdog. Actor death revokes at once (next test).
  test "unresponsive actor expires local authority at the backstop", ctx do
    assert {:ok, guardian, _} = Guardian.start(ctx.resolver, ctx.binding)
    ref = Process.monitor(guardian)
    :sys.suspend(ctx.actor)

    try do
      assert_receive {:DOWN, ^ref, :process, ^guardian, _}, 3600
    after
      :sys.resume(ctx.actor)
    end
  end

  test "actor death revokes local authority immediately", ctx do
    assert {:ok, guardian, _} = Guardian.start(ctx.resolver, ctx.binding)
    ref = Process.monitor(guardian)
    stop_supervised!(Actor)
    assert_receive {:DOWN, ^ref, :process, ^guardian, _}, 500
    assert {:error, :ingress_unavailable} = Runtime.ingress_authority(ctx.view, ctx.binding)
  end

  test "stream owner death cleans the guardian without changing actor lifetime", ctx do
    parent = self()

    owner =
      spawn(fn ->
        {:ok, guardian, _} = Guardian.start(ctx.resolver, ctx.binding)
        send(parent, {:guardian, guardian})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:guardian, guardian}
    ref = Process.monitor(guardian)
    send(owner, :stop)
    assert_receive {:DOWN, ^ref, :process, ^guardian, _}, 1000
    assert Process.alive?(ctx.actor)
  end

  test "runtime resolution requires connected exact local durable authority", ctx do
    assert {:ok, actor, {_executor, command}} = Runtime.ingress_authority(ctx.view, ctx.binding)
    assert actor == ctx.actor and command == ctx.command

    :ok = Execution.runtime_disconnected(ctx.view)
    assert {:error, :ingress_unavailable} = Runtime.ingress_authority(ctx.view, ctx.binding)
    :ok = Execution.runtime_connected(ctx.view)
    assert {:ok, _, _} = Runtime.ingress_authority(ctx.view, ctx.binding)

    for key <- [:host_id, :vm_id, :placement_id] do
      request = Map.put(ctx.binding, key, Lilly.UUID.generate())
      assert {:error, :ingress_unavailable} = Runtime.ingress_authority(ctx.view, request)
    end

    superseding = %{ctx.command | id: Lilly.UUID.generate(), generation: 2}
    {:ok, :stored} = Store.accept(ctx.store, superseding)
    :ok = Execution.intent(ctx.view, superseding)
    assert {:error, :ingress_unavailable} = Runtime.ingress_authority(ctx.view, ctx.binding)
  end
end
