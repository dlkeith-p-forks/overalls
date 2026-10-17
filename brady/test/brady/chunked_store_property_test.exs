defmodule Brady.Cache.ChunkedStorePropertyTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Brady.Cache.Store
  @meta %{"stored_at" => 100, "expires_at" => 200}
  @overhead 24_576

  # @cc [owner:ghuntley,label:verification] brady-unknown-length-independent-budget
  # Generated payload lengths MUST be compared with independent prefix sums;
  # incomplete and interrupted writes MUST never publish or retain reservations.
  property "unknown-length histories reserve exact prefixes and recover complete bytes" do
    check all(
            chunks <- list_of(binary(min_length: 0, max_length: 70_000), max_length: 5),
            finish <- member_of([:commit, :abort, :pressure]),
            max_runs: 35
          ) do
      root = Path.join(System.tmp_dir!(), "brady-chunked-#{System.unique_integer([:positive])}")
      limits = %{quota: 5_000_000, object: 1_000_000, high: 4_500_000, low: 4_000_000}
      {:ok, store} = Store.start_link(root: root, limits: limits)

      try do
        Store.observe(store, 90, 100, true)
        key = String.duplicate("a", 64)
        {:ok, ref} = Store.begin_write(store, key, @meta, :unknown)
        chunks = Enum.flat_map(chunks, &split/1)

        total =
          Enum.reduce(chunks, 0, fn bytes, count ->
            assert :ok = Store.append(store, ref, bytes)
            next = count + byte_size(bytes)
            assert %{pending: pending, objects: 0} = Store.stats(store)
            assert pending == @overhead + next
            assert :miss = Store.open(store, key, 150)
            next
          end)

        case finish do
          :commit ->
            assert :ok = Store.commit(store, ref)
            GenServer.stop(store)
            {:ok, recovered} = Store.start_link(root: root, limits: limits)

            try do
              assert {:ok, reader, @meta, ^total} = Store.open(recovered, key, 150)
              expected = IO.iodata_to_binary(chunks)
              actual = read(recovered, reader, 0, total, [])
              assert actual == expected
              assert :ok = Store.close(recovered, reader)
            after
              GenServer.stop(recovered)
            end

          :abort ->
            assert :ok = Store.abort(store, ref)

          :pressure ->
            Store.observe(store, 0, 100, false)
            assert :bypass = Store.commit(store, ref)
        end

        if finish != :commit, do: assert(Store.stats(store).pending == 0)
      after
        if Process.alive?(store), do: GenServer.stop(store)
        File.rm_rf!(root)
      end
    end
  end

  test "a failed partial write retains its full reservation until removal is confirmed" do
    root =
      Path.join(System.tmp_dir!(), "brady-failed-write-#{System.unique_integer([:positive])}")

    limits = %{quota: 1_000_000, object: 100_000, high: 900_000, low: 800_000}
    {:ok, store} = Store.start_link(root: root, limits: limits)
    Store.observe(store, 90, 100, true)
    {:ok, ref} = Store.begin_write(store, String.duplicate("f", 64), @meta, :unknown)
    state = :sys.get_state(store)
    path = state.writes[ref].path

    try do
      # Execute FD closure in the raw-FD owner, then inject only an IO refusal.
      :sys.replace_state(store, fn current ->
        :file.close(current.writes[ref].file)
        put_in(current.writes[ref].file, :invalid_fixture_file)
      end)

      File.chmod!(path, 0o500)
      assert :bypass = Store.append(store, ref, String.duplicate("x", 4096))
      assert %{pending: pending, writable: false, objects: 0} = Store.stats(store)
      assert pending == @overhead + 4096
      File.chmod!(path, 0o700)
      assert :ok = Store.abort(store, ref)
      assert %{pending: 0, objects: 0} = Store.stats(store)
    after
      File.chmod(path, 0o700)
      GenServer.stop(store)
      File.rm_rf!(root)
    end
  end

  property "generated sizes across zero through 256 MiB stream and reuse with bounded chunks" do
    check all(size <- integer(0..268_435_456), max_runs: 8) do
      root = Path.join(System.tmp_dir!(), "brady-size-#{System.unique_integer([:positive])}")

      limits = %{
        quota: 3_000_000_000,
        object: 268_435_456,
        high: 2_700_000_000,
        low: 2_400_000_000
      }

      {:ok, store} = Store.start_link(root: root, limits: limits)

      try do
        for {framing, index} <- Enum.with_index([:unknown, size]) do
          Store.observe(store, 90, 100, true)
          key = String.duplicate(Integer.to_string(index + 1), 64)
          {:ok, ref} = Store.begin_write(store, key, @meta, framing)
          expected = fill_digest(store, ref, size, :crypto.hash_init(:sha256))
          assert :ok = Store.commit(store, ref)
          {:ok, reader, @meta, ^size} = Store.open(store, key, 150)
          actual = read_digest(store, reader, 0, size, :crypto.hash_init(:sha256))
          assert actual == expected
          Store.close(store, reader)
          assert %{pending: 0} = Store.stats(store)
        end
      after
        GenServer.stop(store)
        File.rm_rf!(root)
      end
    end
  end

  # @cc [owner:ghuntley,label:verification;capacity] brady-wide-store-reservations
  # Known-length admission MUST reserve full multi-GiB lengths plus metadata;
  # object/quota refusal and abort MUST preserve exact overlapping accounting.
  # This sparse admission fixture MUST NOT claim complete large-body delivery.
  property "multi-GiB declared leases retain exact reservations and object refusals" do
    check all(
            boundary <- member_of([2_147_483_648, 4_294_967_296]),
            delta <- member_of([-1, 0, 1, 65_535, 65_536, 65_537]),
            max_runs: 20
          ) do
      cap = boundary + delta
      quota = 2 * (cap + @overhead)
      limits = %{quota: quota, object: cap, high: quota, low: quota - 1}
      root = Path.join(System.tmp_dir!(), "brady-wide-#{System.unique_integer([:positive])}")
      {:ok, store} = Store.start_link(root: root, limits: limits)

      try do
        Store.observe(store, 90, 100, true)
        assert :bypass = Store.begin_write(store, String.duplicate("f", 64), @meta, cap + 1)
        assert %{pending: 0} = Store.stats(store)
        assert {:ok, first} = Store.begin_write(store, String.duplicate("a", 64), @meta, cap)
        assert {:ok, second} = Store.begin_write(store, String.duplicate("b", 64), @meta, cap)
        assert %{pending: ^quota, writers: 2, objects: 0} = Store.stats(store)
        assert :bypass = Store.begin_write(store, String.duplicate("c", 64), @meta, 0)
        assert :ok = Store.append(store, first, <<17>>)
        assert %{pending: ^quota} = Store.stats(store)
        assert :bypass = Store.commit(store, first)
        assert Store.stats(store).pending == cap + @overhead
        assert :ok = Store.abort(store, second)
        assert %{pending: 0, writers: 0, objects: 0} = Store.stats(store)
      after
        GenServer.stop(store)
        File.rm_rf!(root)
      end
    end
  end

  test "expired capacity abandons a fill with a closed cause and no payload diagnostics" do
    root = Path.join(System.tmp_dir!(), "brady-expired-#{System.unique_integer([:positive])}")
    limits = %{quota: 1_000_000, object: 100_000, high: 900_000, low: 800_000}
    {:ok, store} = Store.start_link(root: root, limits: limits)

    try do
      Store.observe(store, 90, 100, true)
      {:ok, ref} = Store.begin_write(store, String.duplicate("a", 64), @meta, :unknown)

      :sys.replace_state(store, fn state ->
        %{state | pressure_deadline: System.monotonic_time(:millisecond) - 1}
      end)

      log =
        ExUnit.CaptureLog.capture_log([formatter: {Brady.Log, %{}}], fn ->
          assert :bypass = Store.append(store, ref, "private-payload-must-not-log")
        end)

      assert log =~ ~s("reason":"pressure_expired")
      refute log =~ "private-payload-must-not-log"
      assert %{pending: 0, writers: 0, objects: 0} = Store.stats(store)
    after
      GenServer.stop(store)
      File.rm_rf!(root)
    end
  end

  @spec fill_digest(pid(), reference(), non_neg_integer(), :crypto.hash_state()) :: binary()
  defp fill_digest(_store, _ref, 0, digest), do: :crypto.hash_final(digest)

  defp fill_digest(store, ref, remaining, digest) do
    Store.observe(store, 90, 100, true)
    bytes = :binary.copy(<<13>>, min(remaining, 65_536))
    assert :ok = Store.append(store, ref, bytes)
    fill_digest(store, ref, remaining - byte_size(bytes), :crypto.hash_update(digest, bytes))
  end

  @spec read_digest(
          pid(),
          reference(),
          non_neg_integer(),
          non_neg_integer(),
          :crypto.hash_state()
        ) :: binary()
  defp read_digest(_store, _ref, _offset, 0, digest), do: :crypto.hash_final(digest)

  defp read_digest(store, ref, offset, remaining, digest) do
    {:ok, bytes} = Store.read(store, ref, offset, min(remaining, 32_768))

    read_digest(
      store,
      ref,
      offset + byte_size(bytes),
      remaining - byte_size(bytes),
      :crypto.hash_update(digest, bytes)
    )
  end

  @spec split(binary()) :: [binary()]
  defp split(<<head::binary-size(65_536), tail::binary>>), do: [head | split(tail)]
  defp split(bytes), do: [bytes]

  @spec read(pid(), reference(), non_neg_integer(), non_neg_integer(), [binary()]) :: binary()
  defp read(_store, _ref, _offset, 0, acc), do: acc |> Enum.reverse() |> IO.iodata_to_binary()

  defp read(store, ref, offset, remaining, acc) do
    {:ok, bytes} = Store.read(store, ref, offset, min(remaining, 65_536))
    read(store, ref, offset + byte_size(bytes), remaining - byte_size(bytes), [bytes | acc])
  end
end
