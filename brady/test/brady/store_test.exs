defmodule Brady.Cache.StoreTest do
  use ExUnit.Case, async: true
  alias Brady.Cache.Store
  @meta %{"stored_at" => 100, "expires_at" => 200}

  setup do
    root = Path.join(System.tmp_dir!(), "brady-store-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm_rf!(root) end)
    limits = %{quota: 1_000_000, object: 100_000, high: 900_000, low: 800_000}
    %{root: root, opts: [root: root, limits: limits]}
  end

  defp key(number),
    do: :crypto.hash(:sha256, Integer.to_string(number)) |> Base.encode16(case: :lower)

  test "unknown pressure refuses writes; exact complete objects survive restart", %{opts: opts} do
    pid = start_supervised!({Store, opts})
    assert :bypass = Store.begin_write(pid, key(1), @meta, 4)
    :ok = Store.observe(pid, 90, 100, true)
    {:ok, ref} = Store.begin_write(pid, key(1), @meta, 4)
    assert :miss = Store.open(pid, key(1), 150)
    assert :ok = Store.append(pid, ref, "data")
    assert :ok = Store.commit(pid, ref)
    assert %{pending: 0, objects: 1} = Store.stats(pid)
    stop_supervised!(Store)
    pid = start_supervised!({Store, opts})
    {:ok, read, @meta, 4} = Store.open(pid, key(1), 150)
    assert {:ok, "data"} = Store.read(pid, read, 0)
    assert {:ok, "at"} = Store.read(pid, read, 1, 2)
    assert :ok = Store.close(pid, read)
    assert :miss = Store.open(pid, key(1), 200)
  end

  test "short and overflowing writes cannot publish", %{opts: opts} do
    pid = start_supervised!({Store, opts})
    Store.observe(pid, 90, 100, true)
    {:ok, ref} = Store.begin_write(pid, key(1), @meta, 4)
    Store.append(pid, ref, "abc")
    assert :bypass = Store.commit(pid, ref)
    {:ok, ref} = Store.begin_write(pid, key(2), @meta, 1)
    assert :bypass = Store.append(pid, ref, "too long")
    assert :miss = Store.open(pid, key(1), 150)
    assert :miss = Store.open(pid, key(2), 150)
    assert %{pending: 0, objects: 0} = Store.stats(pid)
  end

  test "owner death releases reservations and no peer can mutate a lease", %{opts: opts} do
    pid = start_supervised!({Store, opts})
    Store.observe(pid, 90, 100, true)
    parent = self()

    writer =
      spawn(fn ->
        {:ok, ref} = Store.begin_write(pid, key(1), @meta, 4)
        send(parent, {:lease, ref})

        receive do
          :stop -> :ok
        end
      end)

    assert_receive {:lease, ref}
    assert :bypass = Store.append(pid, ref, "data")
    Process.exit(writer, :kill)
    # The monitor event and call come from different senders; poll a bounded
    # number of times rather than assuming mailbox ordering.
    assert eventually(fn -> Store.stats(pid).pending == 0 end)
    assert :miss = Store.open(pid, key(1), 150)
  end

  test "live reader pins an object while pressure evicts other entries", %{opts: opts} do
    pid = start_supervised!({Store, opts})
    Store.observe(pid, 90, 100, true)

    for n <- 1..2 do
      {:ok, ref} = Store.begin_write(pid, key(n), @meta, 4)
      Store.append(pid, ref, "data")
      Store.commit(pid, ref)
    end

    {:ok, read, _, _} = Store.open(pid, key(1), 150)
    Store.observe(pid, 10, 100, true)
    assert %{objects: 1, writable: false} = Store.stats(pid)
    assert {:ok, "data"} = Store.read(pid, read, 0)
    assert :miss = Store.open(pid, key(2), 150)
    Store.close(pid, read)
    Store.observe(pid, 10, 100, true)
    assert %{objects: 0} = Store.stats(pid)
  end

  test "incomplete directories are discarded on restart", %{opts: opts, root: root} do
    pid = start_supervised!({Store, opts})
    Store.observe(pid, 90, 100, true)
    {:ok, ref} = Store.begin_write(pid, key(1), @meta, 4)
    Store.append(pid, ref, "da")
    stop_supervised!(Store)
    pid = start_supervised!({Store, opts})
    assert :miss = Store.open(pid, key(1), 150)
    assert {:ok, []} = File.ls(Path.join(root, "tmp"))
    assert %{pending: 0} = Store.stats(pid)
  end

  defp eventually(fun, attempts \\ 100)
  defp eventually(_, 0), do: false

  defp eventually(fun, attempts) do
    if fun.(),
      do: true,
      else:
        (
          Process.sleep(5)
          eventually(fun, attempts - 1)
        )
  end
end
