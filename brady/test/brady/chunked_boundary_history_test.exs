defmodule Brady.Cache.ChunkedBoundaryHistoryTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Brady.Cache.Store

  @overhead 24_576
  @meta %{"stored_at" => 100, "expires_at" => 200}
  @type command :: {:append, binary()} | :commit | :stop
  @type outcome :: :ok | :bypass
  @type boundary :: :object | :quota | :pool | :parent

  # @cc [owner:ghuntley,label:verification;capacity] chunked-overlapping-boundaries
  # Real overlapping lease owners MUST reserve exact independent prefix sums.
  # Object/quota/pool/parent overflow MUST discard only the offending write; foreign-owner
  # mutation MUST leave both reservations unchanged. The surviving owner's exact
  # bytes MUST publish without admitting the refused object.
  property "overlapping unknown-length owners preserve exact object quota and headroom boundaries" do
    supervisor = start_supervised!(Task.Supervisor)

    check all(
            cap <- member_of([1, 4095, 4096, 65_535]),
            axis <- member_of([:object, :quota, :pool, :parent]),
            reverse <- boolean(),
            max_runs: 12
          ) do
      for {limit, boundary} <- [
            {cap, axis},
            {1, :quota},
            {1, :object},
            {4096, :object},
            {1, :pool},
            {65_535, :parent}
          ] do
        history(supervisor, limit, boundary, reverse)
      end
    end
  end

  # @cc [owner:ghuntley,label:verification;recovery] chunked-owner-process-loss
  # Uncommitted unknown-length prefixes MUST remain unavailable after owner/Store death.
  # A completed commit and an unrelated committed object MUST retain exact bytes
  # after restart. Recovery MUST clear incomplete leases without granting stale
  # references authority. Process loss MUST NOT establish native power-loss proof.
  property "unknown-length process loss preserves only completed payloads" do
    supervisor = start_supervised!(Task.Supervisor)

    check all(
            size <- member_of([0, 1, 65_535, 65_536, 65_537]),
            target <- member_of([:owner, :store]),
            committed <- boolean(),
            max_runs: 8
          ) do
      for {bytes, loss, complete} <- [
            {size, target, committed},
            {0, :owner, false},
            {65_537, :store, false},
            {65_536, :owner, true},
            {1, :store, true}
          ] do
        crash_history(supervisor, bytes, loss, complete)
      end
    end
  end

  @spec crash_history(pid(), non_neg_integer(), :owner | :store, boolean()) :: :ok
  defp crash_history(supervisor, size, target, committed) do
    root = Path.join(System.tmp_dir!(), "brady-loss-#{System.unique_integer([:positive])}")
    limits = %{quota: 1_000_000, object: 100_000, high: 900_000, low: 800_000}
    old_id = {:old_store, make_ref()}
    new_id = {:new_store, make_ref()}

    spec =
      Supervisor.child_spec({Store, root: root, limits: limits}, id: old_id, restart: :temporary)

    store = start_supervised!(spec)
    key = String.duplicate("d", 64)
    neighbor = String.duplicate("e", 64)
    parent = self()
    payload = :binary.copy(<<17>>, size)
    retained = :binary.copy(<<31>>, 37)

    try do
      :ok = Store.observe(store, 90, 100, true)
      {:ok, stable} = Store.begin_write(store, neighbor, @meta, :unknown)
      :ok = Store.append(store, stable, retained)
      :ok = Store.commit(store, stable)
      {:ok, writer} = Task.Supervisor.start_child(supervisor, fn -> owner(store, key, parent) end)
      assert_receive {:lease_ready, ^writer, lease}, 2000
      for bytes <- payload_chunks(payload), do: assert(:ok = ask(writer, {:append, bytes}))
      assert :miss = Store.open(store, key, 150)
      assert Store.stats(store).pending == @overhead + size
      if committed, do: assert(:ok = ask(writer, :commit))

      case target do
        :owner ->
          kill(writer)
          await_no_writers(store, System.monotonic_time(:millisecond) + 2000)
          assert Store.stats(store).pending == 0
          kill(store)

        :store ->
          kill(store)
          kill(writer)
      end

      recovered =
        start_supervised!(Supervisor.child_spec({Store, root: root, limits: limits}, id: new_id))

      assert %{writers: 0, readers: 0, pending: 0, writable: false} = Store.stats(recovered)
      assert File.ls!(Path.join(root, "tmp")) == []
      assert :bypass = Store.append(recovered, lease, <<1>>)
      assert :bypass = Store.commit(recovered, lease)
      assert :ok = Store.abort(recovered, lease)
      assert_object(recovered, neighbor, retained)

      if committed do
        assert_object(recovered, key, payload)
        assert Store.stats(recovered).objects == 2
      else
        assert :miss = Store.open(recovered, key, 150)
        assert Store.stats(recovered).objects == 1
      end

      expected_used =
        @overhead + byte_size(retained) + if(committed, do: @overhead + size, else: 0)

      assert %{used: ^expected_used, pending: 0, readers: 0, writers: 0} = Store.stats(recovered)
      :ok
    after
      stop_supervised(old_id)
      stop_supervised(new_id)
      File.rm_rf!(root)
    end
  end

  @spec payload_chunks(binary()) :: [binary()]
  defp payload_chunks(<<head::binary-size(65_536), rest::binary>>),
    do: [head | payload_chunks(rest)]

  defp payload_chunks(<<>>), do: []
  defp payload_chunks(bytes), do: [bytes]

  @spec assert_object(pid(), String.t(), binary()) :: :ok
  defp assert_object(store, key, expected) do
    size = byte_size(expected)
    assert {:ok, reader, @meta, ^size} = Store.open(store, key, 150)

    if size == 0 do
      assert :eof = Store.read(store, reader, 0, 1)
    else
      Enum.reduce(payload_chunks(expected), 0, fn bytes, offset ->
        assert {:ok, ^bytes} = Store.read(store, reader, offset, byte_size(bytes))
        offset + byte_size(bytes)
      end)
    end

    assert :ok = Store.close(store, reader)
  end

  @spec kill(pid()) :: :ok
  defp kill(pid) do
    monitor = Process.monitor(pid)
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}, 2000
    :ok
  end

  @spec await_no_writers(pid(), integer()) :: :ok
  defp await_no_writers(store, deadline) do
    if Store.stats(store).writers == 0 do
      :ok
    else
      assert System.monotonic_time(:millisecond) < deadline
      await_no_writers(store, deadline)
    end
  end

  @spec history(pid(), pos_integer(), boundary(), boolean()) :: :ok
  defp history(supervisor, cap, axis, reverse) do
    root = Path.join(System.tmp_dir!(), "brady-boundary-#{System.unique_integer([:positive])}")

    quota =
      case axis do
        :object -> 2 * @overhead + 2 * cap + 1
        :quota -> 2 * @overhead + cap
        _ -> 10_000_000
      end

    object =
      if axis in [:pool, :parent], do: 1_000_000, else: cap + if(axis == :quota, do: 1, else: 0)

    limits = %{quota: quota, object: object, high: quota, low: quota - 1}
    id = {:boundary_store, make_ref()}
    store = start_supervised!(Supervisor.child_spec({Store, root: root, limits: limits}, id: id))
    parent = self()
    keys = [String.duplicate("a", 64), String.duplicate("b", 64)]

    try do
      :ok = Store.observe(store, 90, 100, true)
      :ok = constrain_headroom(store, cap, axis)

      owners =
        for key <- keys do
          {:ok, owner} =
            Task.Supervisor.start_child(supervisor, fn -> owner(store, key, parent) end)

          assert_receive {:lease_ready, ^owner, lease}, 2000
          {owner, lease}
        end

      [{first, first_ref}, {second, second_ref}] = owners
      first_size = if axis == :object, do: cap, else: div(cap, 2)
      second_size = if axis == :object, do: div(cap, 2), else: cap - first_size
      first_bytes = :binary.copy(<<13>>, first_size)
      second_bytes = :binary.copy(<<29>>, second_size)
      commands = [{first, first_bytes}, {second, second_bytes}]
      commands = if reverse, do: Enum.reverse(commands), else: commands

      Enum.reduce(commands, 2 * @overhead, fn {pid, bytes}, reserved ->
        assert :ok = ask(pid, {:append, bytes})
        next = reserved + byte_size(bytes)
        assert %{pending: ^next, used: 0, writers: 2, objects: 0} = Store.stats(store)
        next
      end)

      before = Store.stats(store)
      assert :bypass = Store.append(store, first_ref, <<1>>)
      assert :bypass = Store.append(store, second_ref, <<1>>)
      assert Store.stats(store) == before

      for lease <- [first_ref, second_ref] do
        assert :bypass = Store.commit(store, lease)
        assert Store.stats(store) == before
        assert :ok = Store.abort(store, lease)
        assert Store.stats(store) == before
      end

      assert :miss = Store.open(store, hd(keys), 150)
      assert :miss = Store.open(store, List.last(keys), 150)
      assert :bypass = ask(first, {:append, <<7>>})
      survivor_cost = @overhead + second_size
      assert %{pending: ^survivor_cost, used: 0, writers: 1, objects: 0} = Store.stats(store)
      assert :bypass = ask(first, :commit)
      assert :ok = ask(second, :commit)
      assert %{pending: 0, used: ^survivor_cost, writers: 0, objects: 1} = Store.stats(store)
      assert :miss = Store.open(store, hd(keys), 150)
      assert {:ok, reader, @meta, ^second_size} = Store.open(store, List.last(keys), 150)

      if second_size == 0 do
        assert :eof = Store.read(store, reader, 0, 1)
      else
        assert {:ok, ^second_bytes} = Store.read(store, reader, 0, second_size)
      end

      assert :ok = Store.close(store, reader)

      for {pid, _} <- owners do
        monitor = Process.monitor(pid)
        assert :ok = ask(pid, :stop)
        assert_receive {:DOWN, ^monitor, :process, ^pid, :normal}, 2000
      end

      :ok
    after
      stop_supervised(id)
      File.rm_rf!(root)
    end
  end

  @spec constrain_headroom(pid(), pos_integer(), boundary()) :: :ok
  defp constrain_headroom(store, cap, axis) when axis in [:pool, :parent] do
    # Synthetic observations isolate integer budget logic. No native ZFS/mount
    # validation is claimed: pool retains15%, parent20%, plus exact pending room.
    room = 2 * @overhead + cap

    Store.observe_native(store, %{
      quota: 10_000_000,
      total: 100_000_000,
      available: if(axis == :pool, do: 15_000_000 + room, else: 90_000_000),
      parent_total: 100_000_000,
      parent_available: if(axis == :parent, do: 20_000_000 + room, else: 90_000_000),
      deadline: System.monotonic_time(:millisecond) + 60_000
    })
  end

  defp constrain_headroom(_, _, _), do: :ok

  @spec owner(pid(), String.t(), pid()) :: :ok
  defp owner(store, key, parent) do
    {:ok, lease} = Store.begin_write(store, key, @meta, :unknown)
    send(parent, {:lease_ready, self(), lease})
    owner_loop(store, lease)
  end

  @spec owner_loop(pid(), reference()) :: :ok
  defp owner_loop(store, lease) do
    receive do
      {from, receipt, :stop} ->
        send(from, {receipt, :ok})
        :ok

      {from, receipt, command} ->
        result =
          case command do
            {:append, bytes} -> Store.append(store, lease, bytes)
            :commit -> Store.commit(store, lease)
          end

        send(from, {receipt, result})
        owner_loop(store, lease)
    end
  end

  @spec ask(pid(), command()) :: outcome()
  defp ask(owner, command) do
    receipt = make_ref()
    send(owner, {self(), receipt, command})

    receive do
      {^receipt, result} when result in [:ok, :bypass] -> result
    after
      2000 -> flunk("Cache owner did not return its fixed outcome")
    end
  end
end
