defmodule Brady.Cache.RemovalHistoryTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Brady.Cache.Store

  @overhead 24_576
  @meta %{"stored_at" => 100, "expires_at" => 200}

  # @cc [owner:ghuntley,label:verification;capacity] failed-removal-budget-retention
  # Failed IO followed by unconfirmed removal MUST retain the exact full charged
  # reservation across repeated aborts. Confirmed removal MUST reclaim it once,
  # preserve unrelated committed bytes and permit fresh writes after observation.
  # Injected file refusal and local permissions MUST NOT establish native ZFS
  # failure, process interruption inside publication or power-loss acceptance.
  property "unconfirmed removal retains exact charged bytes until confirmed cleanup" do
    check all(
            prefix <- member_of([0, 1, 4096, 65_536]),
            attempted <- member_of([1, 4096, 65_536]),
            retries <- member_of([1, 2, 3]),
            max_runs: 8
          ) do
      for {size, additional} <- [{prefix, attempted}, {0, 1}, {65_536, 65_536}] do
        history(size, additional, retries)
      end
    end
  end

  @spec history(non_neg_integer(), pos_integer(), pos_integer()) :: :ok
  defp history(prefix_size, attempted_size, retries) do
    root =
      Path.join(System.tmp_dir!(), "brady-removal-history-#{System.unique_integer([:positive])}")

    id = {:removal_store, make_ref()}

    store =
      start_supervised!(
        Supervisor.child_spec(
          {Store,
           root: root, limits: %{quota: 1_000_000, object: 200_000, high: 900_000, low: 800_000}},
          id: id
        )
      )

    stable_key = String.duplicate("a", 64)
    failed_key = String.duplicate("b", 64)
    replacement_key = String.duplicate("c", 64)
    retained = "independent-completed-neighbor"
    prefix = :binary.copy(<<17>>, prefix_size)
    :ok = Store.observe(store, 90, 100, true)
    assert {:ok, neighbor} = Store.begin_write(store, stable_key, @meta, :unknown)
    assert :ok = Store.append(store, neighbor, retained)
    assert :ok = Store.commit(store, neighbor)
    assert {:ok, reader, @meta, _} = Store.open(store, stable_key, 150)
    assert {:ok, failed} = Store.begin_write(store, failed_key, @meta, :unknown)
    assert :ok = Store.append(store, failed, prefix)
    path = :sys.get_state(store).writes[failed].path
    used = @overhead + byte_size(retained)
    charged = @overhead + prefix_size + attempted_size

    try do
      # Execute raw FD closure in its Store owner; only the following write's
      # IO handle is injected. Directory permission refusal exercises rm_rf.
      :sys.replace_state(store, fn state ->
        :ok = :file.close(state.writes[failed].file)
        put_in(state.writes[failed].file, :invalid_fixture_file)
      end)

      File.chmod!(path, 0o500)
      assert :bypass = Store.append(store, failed, :binary.copy(<<29>>, attempted_size))

      for _ <- 1..retries do
        assert :ok = Store.abort(store, failed)

        assert %{
                 pending: ^charged,
                 used: ^used,
                 objects: 1,
                 readers: 1,
                 writers: 1,
                 writable: false
               } = Store.stats(store)

        assert File.exists?(path)
        assert :miss = Store.open(store, failed_key, 150)
        assert :bypass = Store.begin_write(store, replacement_key, @meta, :unknown)
        assert {:ok, ^retained} = Store.read(store, reader, 0, byte_size(retained))
      end

      File.chmod!(path, 0o700)
      assert :ok = Store.abort(store, failed)
      refute File.exists?(path)
      assert %{pending: 0, used: ^used, objects: 1, readers: 1, writers: 0} = Store.stats(store)
      before = Store.stats(store)
      assert :ok = Store.abort(store, failed)
      assert Store.stats(store) == before
      assert :ok = Store.observe(store, 90, 100, true)
      assert {:ok, replacement} = Store.begin_write(store, replacement_key, @meta, :unknown)
      assert :ok = Store.append(store, replacement, "resumed")
      assert :ok = Store.commit(store, replacement)
      assert {:ok, next, @meta, 7} = Store.open(store, replacement_key, 150)
      assert {:ok, "resumed"} = Store.read(store, next, 0, 7)
      assert :ok = Store.close(store, next)
      assert :ok = Store.close(store, reader)
      total = used + @overhead + 7
      assert %{pending: 0, used: ^total, objects: 2, readers: 0, writers: 0} = Store.stats(store)
      :ok
    after
      File.chmod(path, 0o700)
      stop_supervised(id)
      File.rm_rf!(root)
    end
  end
end
