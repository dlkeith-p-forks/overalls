defmodule Brady.Cache.PressureHistoryTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Brady.Cache.{Recovery, Store}

  @meta %{"stored_at" => 100, "expires_at" => 200}
  @overhead 24_576
  @type ending :: :missing | :changed_fresh | :changed_stale

  # @cc [owner:ghuntley,label:verification;recovery] repeated-pressure-custody
  # Repeated same-binding stale observations MUST preserve completed readers
  # and refuse new or continuing writes, releasing refused pending leases.
  # Fresh observations MUST permit exact new publication without replacing the
  # existing reader. Changed or missing custody MUST stop the Store while its
  # recovery process survives. Synthetic proof MUST NOT establish native custody.
  property "repeated pressure transitions preserve readers and fence pending writes" do
    payload = draw("payload", binary(min_length: 1, max_length: 65537))
    repetitions = draw("repetitions", member_of([1, 2, 3]))
    ending = draw("ending", member_of([:missing, :changed_fresh, :changed_stale]))

    for {bytes, loss} <- [
          {payload, ending},
          {<<1>>, :missing},
          {:binary.copy(<<19>>, 65_536), :changed_fresh},
          {:binary.copy(<<23>>, 65_537), :changed_stale}
        ] do
      history(bytes, repetitions, loss)
    end
  end

  @spec history(binary(), pos_integer(), ending()) :: :ok
  defp history(payload, repetitions, ending) do
    root =
      Path.join(System.tmp_dir!(), "brady-pressure-history-#{System.unique_integer([:positive])}")

    binding = {"mount", "device"}

    pressure = %{
      total: 100_000_000,
      available: 90_000_000,
      parent_total: 100_000_000,
      parent_available: 90_000_000,
      quota: 10_000_000,
      deadline: System.monotonic_time(:millisecond) + 60_000
    }

    proof_id = {:pressure_proof, make_ref()}
    workers_id = {:pressure_workers, make_ref()}
    recovery_id = {:pressure_recovery, make_ref()}

    proof =
      start_supervised!(
        Supervisor.child_spec({Agent, fn -> {:ok, binding, pressure} end}, id: proof_id)
      )

    workers =
      start_supervised!(
        Supervisor.child_spec({DynamicSupervisor, strategy: :one_for_one}, id: workers_id)
      )

    recovery =
      start_supervised!(
        Supervisor.child_spec(
          {Recovery,
           workers: workers,
           ready: fn -> Agent.get(proof, & &1) end,
           store: [
             root: root,
             limits: %{quota: 10_000_000, object: 1_000_000, high: 9_000_000, low: 8_000_000}
           ]},
          id: recovery_id
        )
      )

    try do
      sync_pressure(recovery)
      assert [{_, store, :worker, _}] = DynamicSupervisor.which_children(workers)
      key = String.duplicate("a", 64)
      assert {:ok, write} = Store.begin_write(store, key, @meta, :unknown)
      append(store, write, payload)
      assert :ok = Store.commit(store, write)
      size = byte_size(payload)
      used = @overhead + size
      assert {:ok, reader, @meta, ^size} = Store.open(store, key, 101)

      for generation <- 1..repetitions do
        pending_key = :crypto.hash(:sha256, <<generation>>) |> Base.encode16(case: :lower)
        assert {:ok, pending} = Store.begin_write(store, pending_key, @meta, :unknown)
        append(store, pending, payload)
        assert %{pending: ^used, used: ^used, readers: 1, writers: 1} = Store.stats(store)
        Agent.update(proof, fn _ -> {:stale, binding} end)
        sync_pressure(recovery)
        sync_pressure(recovery)

        assert %{pending: ^used, used: ^used, readers: 1, writers: 1, writable: false} =
                 Store.stats(store)

        assert :bypass = Store.begin_write(store, String.duplicate("c", 64), @meta, :unknown)
        assert :bypass = Store.append(store, pending, <<1>>)
        assert :bypass = Store.commit(store, pending)
        assert %{pending: 0, used: ^used, objects: 1, readers: 1, writers: 0} = Store.stats(store)
        assert File.ls!(Path.join(root, "tmp")) == []
        read(store, reader, payload, 0)
        assert :miss = Store.open(store, pending_key, 101)
        Agent.update(proof, fn _ -> {:ok, binding, pressure} end)
        sync_pressure(recovery)
        assert Store.stats(store).writable
        assert {:ok, resumed} = Store.begin_write(store, pending_key, @meta, :unknown)
        append(store, resumed, payload)
        assert :ok = Store.commit(store, resumed)
        assert {:ok, other, @meta, ^size} = Store.open(store, pending_key, 101)
        read(store, other, payload, 0)
        assert :ok = Store.close(store, other)
        # Remove only the new object through the real pressure eviction path;
        # the original active reader keeps its object pinned.
        assert :ok = Store.observe(store, 10, 100, true)
        assert %{objects: 1, used: ^used, readers: 1} = Store.stats(store)
        sync_pressure(recovery)
      end

      monitor = Process.monitor(store)

      loss =
        case ending do
          :missing -> :error
          :changed_fresh -> {:ok, {"replacement", "device"}, pressure}
          :changed_stale -> {:stale, {"replacement", "device"}}
        end

      Agent.update(proof, fn _ -> loss end)
      sync_pressure(recovery)
      assert_receive {:DOWN, ^monitor, :process, ^store, :shutdown}, 2000
      assert Process.alive?(recovery)
      assert DynamicSupervisor.which_children(workers) == []
      :ok
    after
      stop_supervised(recovery_id)
      stop_supervised(workers_id)
      stop_supervised(proof_id)
      File.rm_rf!(root)
    end
  end

  @spec sync_pressure(pid()) :: :ok
  defp sync_pressure(recovery) do
    send(recovery, :check)
    :sys.get_state(recovery)
    :ok
  end

  @spec append(pid(), reference(), binary()) :: :ok
  defp append(_, _, <<>>), do: :ok

  defp append(store, lease, bytes) do
    size = min(byte_size(bytes), 65_536)
    <<part::binary-size(^size), rest::binary>> = bytes
    assert :ok = Store.append(store, lease, part)
    append(store, lease, rest)
  end

  @spec read(pid(), reference(), binary(), non_neg_integer()) :: :ok
  defp read(_, _, <<>>, _), do: :ok

  defp read(store, lease, bytes, offset) do
    size = min(byte_size(bytes), 65_536)
    <<part::binary-size(^size), rest::binary>> = bytes
    assert {:ok, ^part} = Store.read(store, lease, offset, size)
    read(store, lease, rest, offset + size)
  end
end
