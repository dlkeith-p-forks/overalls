defmodule Lilly.IngressBridgesTest do
  @moduledoc """
  Detached ingress bridges (ADR-0187): the connector's reservation, record,
  keeper and re-adoption logic against a fake host. hostd's scopes, the
  namespace dial and survival across a real hostd restart are covered by the
  user-SSH journey machine test, not here.
  """
  use ExUnit.Case, async: true
  alias Lilly.Ingress.Bridges
  alias OverallsProtocol.IngressConnect, as: Wire
  @id "11111111-1111-4111-8111-111111111111"

  defmodule Host do
    @moduledoc "Live bridges in an Agent; ending one reports to the test."
    def live({agent, _parent}), do: {:ok, Agent.get(agent, &MapSet.to_list/1)}

    def end_bridge({agent, parent}, key) do
      Agent.update(agent, &MapSet.delete(&1, key))
      send(parent, {:ended, key})
      :ok
    end
  end

  defmodule Backend do
    @moduledoc "Bridges by writing the greeting itself; guards with the test's guardian."
    def bridge({parent, agent, guardian}, binding, socket, key, greeting) do
      :ok = :inet.setopts(socket, packet: 0)
      :ok = :gen_tcp.send(socket, greeting)
      Agent.update(agent, &MapSet.put(&1, key))
      send(parent, {:bridged, key, binding})
      {:bridged, guardian}
    end

    def guard({parent, _agent, guardian}, binding) do
      send(parent, {:guarded, binding})
      if Process.alive?(guardian), do: {:ok, guardian}, else: {:error, :ingress_unavailable}
    end
  end

  setup do
    directory =
      Path.join(System.tmp_dir!(), "lilly-bridges-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    {:ok, %{uid: uid}} = File.stat(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    {:ok, agent} = Agent.start_link(fn -> MapSet.new() end)

    binding = %{
      vm_id: @id,
      host_id: @id,
      placement_id: @id,
      session_id: @id,
      execution_epoch: 1,
      generation: 1,
      service: :ssh,
      port: 22,
      label: OverallsProtocol.IngressName.label("vm", @id)
    }

    path = Path.join(directory, "connector.sock")
    %{path: path, uid: uid, binding: binding, agent: agent, records: Bridges.directory(path)}
  end

  defp guardian do
    pid =
      spawn(fn ->
        receive do
          :stop -> :ok
        end
      end)

    on_exit(fn -> Process.exit(pid, :kill) end)
    pid
  end

  defp server(ctx, guardian) do
    start_supervised!(
      {Lilly.Ingress.Server,
       path: ctx.path,
       audi_uid: ctx.uid,
       host_id: @id,
       backend: {Backend, {self(), ctx.agent, guardian}},
       bridge_host: {Host, {ctx.agent, self()}}}
    )
  end

  # @cc [owner:ghuntley,label:verification;security] ingress-detached-handoff-fixture
  # A detached handoff MUST deliver the greeting, record the exact binding
  # under the bridge's key before the bridge exists, give it a keeper that
  # guards the same binding, and end it through the host as soon as that
  # guardian dies, removing the record.
  test "a detached bridge is recorded, kept and ended when its guardian dies", ctx do
    guardian = guardian()
    server(ctx, guardian)
    {:ok, client} = :gen_tcp.connect({:local, ctx.path}, 0, [:binary, active: false, packet: 4])
    {:ok, message} = Wire.encode(ctx.binding)
    :ok = :gen_tcp.send(client, message)
    assert {:ok, ready} = :gen_tcp.recv(client, 0, 2000)
    assert Wire.ready?(ready)
    assert_receive {:bridged, key, binding}, 2000
    assert binding == ctx.binding
    assert {:ok, bytes} = File.read(Path.join(ctx.records, Bridges.name(key)))
    assert {:ok, ^binding} = Wire.decode(bytes)
    assert_receive {:guarded, ^binding}, 2000
    refute_receive {:ended, _}, 300
    send(guardian, :stop)
    assert_receive {:ended, ^key}, 3000
    Process.sleep(50)
    refute File.exists?(Path.join(ctx.records, Bridges.name(key)))
  end

  # @cc [owner:ghuntley,label:verification;recovery] ingress-readoption-fixture
  # A restarted connector MUST give a recorded live bridge a keeper for its
  # recorded binding, end a live bridge without a record, drop records of
  # bridges no longer live, and stop a keeper whose bridge ended without
  # ending anything.
  test "a restarted connector re-adopts recorded bridges and ends unknown ones", ctx do
    guardian = guardian()
    :ok = Lilly.Host.PrivateFiles.directory(ctx.records)
    [kept, unknown, stale] = for _ <- 1..3, do: Bridges.new_key()
    :ok = Bridges.record(ctx.records, kept, ctx.binding)
    :ok = Bridges.record(ctx.records, stale, ctx.binding)
    Agent.update(ctx.agent, fn _ -> MapSet.new([kept, unknown]) end)
    server(ctx, guardian)
    assert_receive {:ended, ^unknown}, 3000
    assert_receive {:guarded, binding}, 3000
    assert binding == ctx.binding
    refute File.exists?(Path.join(ctx.records, Bridges.name(stale)))
    assert File.exists?(Path.join(ctx.records, Bridges.name(kept)))
    Agent.update(ctx.agent, &MapSet.delete(&1, kept))
    Process.sleep(2600)
    refute_received {:ended, ^kept}
    refute File.exists?(Path.join(ctx.records, Bridges.name(kept)))
  end

  # @cc [owner:ghuntley,label:verification;security] ingress-unadopted-bridge-ended
  # A recorded bridge whose execution never becomes current again MUST be
  # ended once its keeper's grace passes.
  test "a recorded bridge that cannot be guarded is ended", ctx do
    dead = guardian()
    send(dead, :stop)
    :ok = Lilly.Host.PrivateFiles.directory(ctx.records)
    key = Bridges.new_key()
    :ok = Bridges.record(ctx.records, key, ctx.binding)
    Agent.update(ctx.agent, fn _ -> MapSet.new([key]) end)
    Process.sleep(20)

    keeper =
      Bridges.start_keeper(
        {Backend, {self(), ctx.agent, dead}},
        {Host, {ctx.agent, self()}},
        ctx.records,
        key,
        ctx.binding,
        :handoff
      )

    assert_receive {:guarded, _}
    assert_receive {:ended, ^key}, 4000
    ref = Process.monitor(keeper)
    assert_receive {:DOWN, ^ref, :process, _, :normal}, 2000
    refute File.exists?(Path.join(ctx.records, Bridges.name(key)))
  end
end
