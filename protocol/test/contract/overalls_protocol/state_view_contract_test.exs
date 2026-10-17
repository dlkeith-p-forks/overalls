defmodule OverallsProtocolStateViewContractTest do
  use Covenant.Case, component: "overalls_protocol.state_view"

  @tag obligation: "overalls_protocol.state_view.I1"
  test "declared modules compile and remain loadable" do
    modules = [OverallsProtocol.Cadence, OverallsProtocol.NestedStream, OverallsProtocol.View]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end

  @tag obligation: "overalls_protocol.state_view.I2"
  test "cadence coalesces requests while running" do
    cadence = OverallsProtocol.Cadence.new()
    assert {:ok, cadence, [:start]} = OverallsProtocol.Cadence.step(cadence, :tick)
    assert {:ok, cadence, []} = OverallsProtocol.Cadence.step(cadence, :tick)
    assert {:ok, cadence, []} = OverallsProtocol.Cadence.step(cadence, :request)
    assert {:ok, next, [:start]} = OverallsProtocol.Cadence.step(cadence, :done)
    assert next.state == :running

    assert {:error, :invalid_transition} =
             OverallsProtocol.Cadence.step(OverallsProtocol.Cadence.new(), :done)
  end

  @tag obligation: "overalls_protocol.state_view.I3"
  test "view ownership and versions are enforced" do
    name = :covenant_view
    {:ok, pid} = OverallsProtocol.View.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    assert :ok = OverallsProtocol.View.claim(name, :key)
    caller = self()
    spawn(fn -> send(caller, OverallsProtocol.View.claim(name, :key)) end)
    assert_receive {:error, :claimed}
    assert {:ok, v1} = OverallsProtocol.View.put(name, :key, :one)
    assert {:ok, {^v1, :one}} = OverallsProtocol.View.fetch(name, :key)
    assert :ok = OverallsProtocol.View.release(name, :key)
    assert :error = OverallsProtocol.View.fetch(name, :key)
  end

  @tag obligation: "overalls_protocol.state_view.I4"
  test "view index and subscribers track deletion" do
    name = :covenant_view_notify
    {:ok, pid} = OverallsProtocol.View.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    assert :ok = OverallsProtocol.View.claim(name, :key)
    assert :ok = OverallsProtocol.View.subscribe(name, [:key])
    assert {:ok, _} = OverallsProtocol.View.put(name, :key, :value, [:tag])
    assert_receive {:view_changed, ^name, :key}
    assert [{:key, _, :value}] = OverallsProtocol.View.lookup(name, :tag)
    assert :ok = OverallsProtocol.View.delete(name, :key)
    assert_receive {:view_changed, ^name, :key}
    assert [] = OverallsProtocol.View.lookup(name, :tag)
  end

  @tag obligation: "overalls_protocol.state_view.I5"
  test "owner death revokes rows and notifies subscribers" do
    name = :covenant_view_owner_down
    {:ok, pid} = OverallsProtocol.View.start_link(name: name)
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    assert :ok = OverallsProtocol.View.subscribe(name, [:key])
    parent = self()

    owner =
      spawn(fn ->
        send(parent, OverallsProtocol.View.claim(name, :key))

        receive do
          :publish ->
            send(parent, OverallsProtocol.View.put(name, :key, :value))
            Process.sleep(:infinity)
        end
      end)

    assert_receive :ok
    send(owner, :publish)

    assert_receive {:ok, _version}
    assert_receive {:view_changed, ^name, :key}
    Process.exit(owner, :kill)
    assert_receive {:view_changed, ^name, :key}, 1_000
    assert :error = OverallsProtocol.View.fetch(name, :key)
  end
end
