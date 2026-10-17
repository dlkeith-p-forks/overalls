defmodule Brady.CacheRecoveryTest do
  use ExUnit.Case, async: true

  test "failed storage does not take down recovery and repaired storage starts unwritable" do
    root = Path.join(System.tmp_dir!(), "brady-recovery-#{System.unique_integer([:positive])}")
    File.write!(root, "not a directory")
    on_exit(fn -> File.rm_rf!(root) end)
    workers = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    recovery =
      start_supervised!(
        {Brady.Cache.Recovery,
         workers: workers,
         store: [
           root: root,
           limits: %{quota: 1_000_000, object: 100_000, high: 900_000, low: 800_000}
         ]}
      )

    :sys.get_state(recovery)
    assert Process.alive?(recovery)
    assert DynamicSupervisor.which_children(workers) == []

    assert Brady.Cache.lookup(
             :missing_recovery_fixture,
             %{
               method: "GET",
               scheme: :https,
               host: "origin.example",
               port: 443,
               target: "/",
               headers: []
             },
             System.system_time(:second)
           ) ==
             :miss

    File.rm!(root)
    Process.sleep(5_100)
    assert [{_, store, :worker, _}] = DynamicSupervisor.which_children(workers)
    refute Brady.Cache.Store.stats(store).writable
    assert Process.alive?(recovery)
  end

  test "missing proof prevents cache initialization and lost mount custody stops only the store" do
    root = Path.join(System.tmp_dir!(), "brady-custody-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, proof} = Agent.start_link(fn -> :error end)
    workers = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    recovery =
      start_supervised!(
        {Brady.Cache.Recovery,
         workers: workers,
         ready: fn -> Agent.get(proof, & &1) end,
         store: [
           root: root,
           limits: %{quota: 1_000_000, object: 100_000, high: 900_000, low: 800_000}
         ]}
      )

    :sys.get_state(recovery)
    refute File.exists?(root)
    Agent.update(proof, fn _ -> {:ok, {"mount", "device"}, nil} end)
    Process.sleep(5_100)
    assert [{_, store, :worker, _}] = DynamicSupervisor.which_children(workers)
    monitor = Process.monitor(store)
    Agent.update(proof, fn _ -> {:ok, {"replacement", "device"}, nil} end)
    send(recovery, :check)
    assert_receive {:DOWN, ^monitor, :process, ^store, :shutdown}, 2_000
    assert Process.alive?(recovery)
    assert DynamicSupervisor.which_children(workers) == []
  end

  test "stale same-mount pressure preserves completed reads and refuses writes until fresh" do
    root = Path.join(System.tmp_dir!(), "brady-stale-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)

    pressure = %{
      total: 100_000_000,
      available: 90_000_000,
      parent_total: 100_000_000,
      parent_available: 90_000_000,
      quota: 10_000_000,
      deadline: System.monotonic_time(:millisecond) + 60_000
    }

    binding = {"mount", "device"}
    proof = start_supervised!({Agent, fn -> {:ok, binding, pressure} end})
    workers = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    recovery =
      start_supervised!(
        {Brady.Cache.Recovery,
         workers: workers,
         ready: fn -> Agent.get(proof, & &1) end,
         store: [
           root: root,
           limits: %{quota: 10_000_000, object: 1_000_000, high: 9_000_000, low: 8_000_000}
         ]}
      )

    :sys.get_state(recovery)
    send(recovery, :check)
    :sys.get_state(recovery)
    assert [{_, store, :worker, _}] = DynamicSupervisor.which_children(workers)
    key = String.duplicate("a", 64)

    {:ok, write} =
      Brady.Cache.Store.begin_write(store, key, %{"stored_at" => 100, "expires_at" => 200}, 3)

    :ok = Brady.Cache.Store.append(store, write, "abc")
    :ok = Brady.Cache.Store.commit(store, write)
    {:ok, lease, _, 3} = Brady.Cache.Store.open(store, key, 101)

    {:ok, pending} =
      Brady.Cache.Store.begin_write(
        store,
        String.duplicate("b", 64),
        %{"stored_at" => 100, "expires_at" => 200},
        :unknown
      )

    Agent.update(proof, fn _ -> {:stale, binding} end)
    send(recovery, :check)
    :sys.get_state(recovery)
    assert Process.alive?(store)
    refute Brady.Cache.Store.stats(store).writable
    assert :bypass = Brady.Cache.Store.begin_write(store, String.duplicate("c", 64), %{}, 1)
    assert :bypass = Brady.Cache.Store.append(store, pending, "x")
    assert {:ok, "abc"} = Brady.Cache.Store.read(store, lease, 0)
    assert {:ok, another, _, 3} = Brady.Cache.Store.open(store, key, 101)
    :ok = Brady.Cache.Store.close(store, another)
    Agent.update(proof, fn _ -> {:ok, binding, pressure} end)
    send(recovery, :check)
    :sys.get_state(recovery)
    assert Brady.Cache.Store.stats(store).writable
    assert {:ok, "abc"} = Brady.Cache.Store.read(store, lease, 0)
    :ok = Brady.Cache.Store.close(store, lease)
    monitor = Process.monitor(store)
    Agent.update(proof, fn _ -> {:stale, {"changed", "device"}} end)
    send(recovery, :check)
    assert_receive {:DOWN, ^monitor, :process, ^store, :shutdown}, 2_000
  end
end
