defmodule Brady.Cache.Store do
  @moduledoc "Disposable sharded object store. One owner serializes budgets, publication and leases."
  use GenServer
  require Brady.Events
  alias Brady.Cache.Budget
  @chunk 65_536
  @metadata_limit 16_384
  @overhead 24_576
  @key ~r/\A[0-9a-f]{64}\z/
  @type server :: GenServer.server()
  @type body_size :: non_neg_integer() | :unknown

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, Keyword.take(opts, [:name]))
  @spec observe(server(), term(), term(), boolean()) :: :ok
  def observe(server, available, total, safe),
    do: GenServer.call(server, {:observe, available, total, safe})

  @spec begin_write(server(), String.t(), map(), body_size()) ::
          {:ok, reference()} | :bypass
  def begin_write(server, key, metadata, size),
    do: GenServer.call(server, {:begin, key, metadata, size})

  @spec append(server(), reference(), binary()) :: :ok | :bypass
  def append(server, ref, bytes), do: GenServer.call(server, {:append, ref, bytes})
  @spec commit(server(), reference()) :: :ok | :bypass
  def commit(server, ref), do: GenServer.call(server, {:commit, ref})
  @spec abort(server(), reference()) :: :ok
  def abort(server, ref), do: GenServer.call(server, {:abort, ref})

  @spec open(server(), String.t(), integer()) ::
          {:ok, reference(), map(), non_neg_integer()} | :miss
  def open(server, key, now), do: GenServer.call(server, {:open, key, now})

  @spec read(server(), reference(), non_neg_integer(), pos_integer()) ::
          {:ok, binary()} | :eof | {:error, :storage}
  def read(server, ref, offset, size \\ @chunk),
    do: GenServer.call(server, {:read, ref, offset, size})

  @spec close(server(), reference()) :: :ok
  def close(server, ref), do: GenServer.call(server, {:close, ref})
  @spec stats(server()) :: map()
  def stats(server), do: GenServer.call(server, :stats)

  @impl true
  def init(opts) do
    root = Keyword.fetch!(opts, :root)
    limits = Keyword.fetch!(opts, :limits)

    state = %{
      root: root,
      limits: limits,
      entries: %{},
      writes: %{},
      reads: %{},
      used: 0,
      pending: 0,
      writable: false,
      pressure_at: nil,
      headroom: nil,
      pressure_deadline: nil,
      clock: 0,
      max_entries: Keyword.get(opts, :max_entries, 8192),
      max_leases: Keyword.get(opts, :max_leases, 256)
    }

    with true <- Path.type(root) == :absolute and Path.expand(root) == root,
         :ok <- private_directory(root),
         :ok <- private_directory(Path.join(root, "objects")),
         :ok <- cleanup_temp(root),
         {:ok, recovered} <- recover(state) do
      {:ok, recovered}
    else
      _ -> {:stop, :cache_storage_unavailable}
    end
  end

  # @cc [owner:ghuntley,label:capacity] brady-stale-pressure-read-only
  # Stale capacity with independently confirmed unchanged mount custody MUST
  # deny new/continuing writes without evicting complete objects or active reads.
  @spec pause_writes(server()) :: :ok
  def pause_writes(server), do: GenServer.call(server, :pause_writes)

  @spec observe_native(server(), map()) :: :ok
  def observe_native(server, observation),
    do: GenServer.call(server, {:native_pressure, observation})

  # @cc [owner:ghuntley,label:security] brady-store-status-redacted
  # OTP status and crash formatting MUST NOT expose stored response headers or
  # open write metadata. Diagnostics may expose bounded counts only.
  @impl true
  def format_status(status), do: Map.put(status, :state, :redacted)

  @impl true
  def handle_call(:pause_writes, _, state), do: {:reply, :ok, %{state | writable: false}}

  def handle_call({:observe, available, total, safe}, _, state) do
    writable = Budget.writable?(state.writable, available, total, safe)
    state = %{state | writable: writable, pressure_at: System.monotonic_time(:millisecond)}
    state = if below_floor?(available, total, safe), do: evict(state, 0), else: state
    {:reply, :ok, state}
  end

  # @cc [owner:ghuntley,label:capacity] brady-native-quota-and-pending-pressure
  # Native observations MUST constrain quota and pending writes together. Pool and
  # guest-parent headroom MUST retain 15 and 20 percent respectively; pending leases
  # MUST be deducted conservatively before enabling writes or admitting a lease.
  def handle_call({:native_pressure, p}, _, state) do
    limits = %{
      quota: p.quota,
      object: min(16 * 1_073_741_824, div(p.quota, 10)),
      high: div(p.quota * 90, 100),
      low: div(p.quota * 80, 100)
    }

    headroom =
      max(
        0,
        min(
          p.available - div(p.total * 15 + 99, 100),
          p.parent_available - div(p.parent_total * 20 + 99, 100)
        )
      )

    available = max(0, p.available - state.pending)
    parent_safe = p.parent_available - state.pending >= div(p.parent_total * 20 + 99, 100)

    fresh? = p.deadline > System.monotonic_time(:millisecond)
    writable = Budget.writable?(state.writable, available, p.total, parent_safe) and fresh?

    state = %{
      state
      | limits: limits,
        headroom: headroom,
        pressure_deadline: p.deadline,
        writable: writable,
        pressure_at: System.monotonic_time(:millisecond)
    }

    state =
      cond do
        below_floor?(available, p.total, parent_safe) -> evict(state, 0)
        # Late (stale) evidence or the resume hysteresis band: read-only, keep objects.
        not writable -> state
        state.used + state.pending >= limits.high -> evict(state, limits.low)
        true -> state
      end

    {:reply, :ok, state}
  end

  # @cc [owner:ghuntley,label:capacity] brady-store-admission-reservation
  # Before opening a write, reserve its declared body (or zero for unknown length)
  # and bounded metadata cost atomically. Unknown-length appends MUST reserve each
  # additional payload before writing, within object, quota and headroom bounds.
  # Missing/stale pressure, an existing key, or exhausted object,
  # memory/lease and disk bounds MUST bypass storage. Only the lease owner may
  # mutate it; owner death MUST abort unfinished publication.
  def handle_call({:begin, key, metadata, size}, {owner, _}, state) do
    state =
      if state.used + state.pending >= state.limits.high,
        do: evict(state, state.limits.low),
        else: state

    with true <- valid_key?(key) and (size == :unknown or valid_size?(size, state)),
         true <- writable?(state),
         true <- map_size(state.entries) + map_size(state.writes) < state.max_entries,
         true <- map_size(state.reads) + map_size(state.writes) < state.max_leases,
         false <- Map.has_key?(state.entries, key),
         false <- Enum.any?(state.writes, fn {_, w} -> w.key == key end),
         {:ok, encoded} <- encode_metadata(metadata, if(size == :unknown, do: 0, else: size)),
         reserved = if(size == :unknown, do: @overhead, else: size + @overhead),
         true <- Budget.fits?(state.limits.quota, state.used, state.pending, reserved),
         true <- is_nil(state.headroom) or state.pending + reserved <= state.headroom,
         path =
           Path.join([
             state.root,
             "tmp",
             Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
           ]),
         {:ok, file} <- create_write(path) do
      ref = Process.monitor(owner)

      write = %{
        owner: owner,
        key: key,
        path: path,
        file: file,
        size: size,
        written: 0,
        reserved: reserved,
        metadata: metadata,
        encoded: encoded
      }

      Brady.Events.emit("brady.cache_write_admitted",
        framing: if(size == :unknown, do: :chunked, else: :known)
      )

      {:reply, {:ok, ref},
       %{state | writes: Map.put(state.writes, ref, write), pending: state.pending + reserved}}
    else
      _ -> {:reply, :bypass, state}
    end
  end

  def handle_call({:append, ref, bytes}, {owner, _}, state) do
    case state.writes[ref] do
      %{owner: ^owner} = write ->
        additional = if write.size == :unknown and is_binary(bytes), do: byte_size(bytes), else: 0

        if is_binary(bytes) and byte_size(bytes) <= @chunk and
             write.written + byte_size(bytes) <= state.limits.object and
             (write.size == :unknown or
                (write.written + byte_size(bytes) <= write.size and
                   write.size <= state.limits.object)) and
             writable?(state) and
             Budget.fits?(state.limits.quota, state.used, state.pending, additional) and
             (is_nil(state.headroom) or state.pending + additional <= state.headroom) do
          # Retain the entire admitted reservation even if a partial disk write
          # fails and removal cannot be confirmed.
          reserved = %{write | reserved: write.reserved + additional}
          state = %{state | pending: state.pending + additional}
          state = put_in(state.writes[ref], reserved)

          case :file.write(write.file, bytes) do
            :ok ->
              next = %{reserved | written: write.written + byte_size(bytes)}
              {:reply, :ok, put_in(state.writes[ref], next)}

            _ ->
              write_refused(state, :io)
              {:reply, :bypass, discard_write(state, ref)}
          end
        else
          write_refused(state, append_refusal(state, write, bytes, additional))
          {:reply, :bypass, discard_write(state, ref)}
        end

      _ ->
        {:reply, :bypass, state}
    end
  end

  # @cc [owner:ghuntley,label:recovery] brady-store-complete-publication
  # An object MUST become visible only after exact declared length (or the caller
  # confirms valid chunked termination), successful
  # data sync/close, metadata write and atomic directory rename. Incomplete or
  # failed writes MUST never be indexed, including after a process restart.
  def handle_call({:commit, ref}, {owner, _}, state) do
    case state.writes[ref] do
      %{owner: ^owner} = write ->
        destination = object_path(state.root, write.key)
        size = if write.size == :unknown, do: write.written, else: write.size

        with true <- write.written == size and size <= state.limits.object and writable?(state),
             {:ok, encoded} <- encode_metadata(write.metadata, size),
             :ok <- :file.sync(write.file),
             :ok <- :file.close(write.file),
             :ok <-
               File.write(Path.join(write.path, "metadata.json"), encoded, [
                 :exclusive,
                 :sync
               ]),
             :ok <- private_directory(Path.dirname(destination)),
             :ok <- File.rename(write.path, destination) do
          Process.demonitor(ref, [:flush])

          Brady.Events.emit("brady.cache_write_finished",
            outcome: :published,
            payload_chunks: div(size + @chunk - 1, @chunk)
          )

          entry = %{
            metadata: write.metadata,
            size: size,
            cost: write.reserved,
            access: state.clock
          }

          {:reply, :ok,
           %{
             state
             | entries: Map.put(state.entries, write.key, entry),
               writes: Map.delete(state.writes, ref),
               used: state.used + write.reserved,
               pending: state.pending - write.reserved,
               clock: state.clock + 1
           }}
        else
          _ -> {:reply, :bypass, discard_write(state, ref)}
        end

      _ ->
        {:reply, :bypass, state}
    end
  end

  def handle_call({:abort, ref}, {owner, _}, state) do
    state =
      if match?(%{owner: ^owner}, state.writes[ref]), do: discard_write(state, ref), else: state

    {:reply, :ok, state}
  end

  def handle_call({:open, key, now}, {owner, _}, state) do
    state = expire(state, key, now)

    with true <- valid_key?(key),
         %{metadata: metadata} = entry <- state.entries[key],
         true <- is_integer(now) and now >= metadata["stored_at"] and now < metadata["expires_at"],
         true <- map_size(state.reads) + map_size(state.writes) < state.max_leases,
         path = Path.join(object_path(state.root, key), "body"),
         {:ok, %{type: :regular, size: size, links: 1}} <- File.lstat(path),
         true <- size == entry.size,
         {:ok, file} <- :file.open(String.to_charlist(path), [:read, :binary, :raw]) do
      ref = Process.monitor(owner)
      read = %{owner: owner, key: key, file: file, size: size}

      state = %{
        state
        | reads: Map.put(state.reads, ref, read),
          clock: state.clock + 1,
          entries: Map.put(state.entries, key, %{entry | access: state.clock})
      }

      {:reply, {:ok, ref, metadata, size}, state}
    else
      _ -> {:reply, :miss, state}
    end
  end

  def handle_call({:read, ref, offset, size}, {owner, _}, state) do
    result =
      with %{owner: ^owner} = read <- state.reads[ref],
           true <- is_integer(offset) and offset >= 0 and offset <= read.size,
           true <- is_integer(size) and size > 0 and size <= @chunk do
        :file.pread(read.file, offset, min(size, read.size - offset))
      else
        _ -> {:error, :storage}
      end

    result =
      case result do
        {:ok, bytes} -> {:ok, bytes}
        :eof -> :eof
        _ -> {:error, :storage}
      end

    {:reply, result, state}
  end

  def handle_call({:close, ref}, {owner, _}, state) do
    state = if match?(%{owner: ^owner}, state.reads[ref]), do: close_read(state, ref), else: state
    {:reply, :ok, state}
  end

  def handle_call(:stats, _, state) do
    {:reply,
     %{
       used: state.used,
       pending: state.pending,
       objects: map_size(state.entries),
       writers: map_size(state.writes),
       readers: map_size(state.reads),
       writable: writable?(state)
     }, state}
  end

  @impl true
  def handle_info({:DOWN, ref, :process, _, _}, state),
    do: {:noreply, state |> discard_write(ref) |> close_read(ref)}

  @impl true
  def terminate(_, state) do
    Enum.each(state.writes, fn {_, w} -> :file.close(w.file) end)
    Enum.each(state.reads, fn {_, r} -> :file.close(r.file) end)
  end

  @type refusal ::
          :io
          | :payload
          | :object
          | :declared_length
          | :pressure_expired
          | :pressure_paused
          | :quota
          | :headroom

  # @cc [owner:ghuntley,label:logging] brady-refusal-closed-cause
  # Append refusal diagnostics MUST contain only a fixed cause and bounded
  # freshness durations, never raw IO errors, payloads, paths or per-chunk logs.
  @spec write_refused(map(), refusal()) :: :ok
  defp write_refused(state, reason) do
    now = System.monotonic_time(:millisecond)
    age = if is_integer(state.pressure_at), do: now - state.pressure_at, else: 0
    remaining = if is_integer(state.pressure_deadline), do: state.pressure_deadline - now, else: 0

    Brady.Events.emit("brady.cache_write_refused",
      reason: reason,
      observation_age_ms: min(2_147_483_647, max(0, age)),
      capacity_remaining_ms: min(2_147_483_647, max(0, remaining))
    )
  end

  @spec append_refusal(map(), map(), term(), non_neg_integer()) :: refusal()
  defp append_refusal(state, write, bytes, additional) do
    now = System.monotonic_time(:millisecond)

    cond do
      not is_binary(bytes) or byte_size(bytes) > @chunk -> :payload
      write.written + byte_size(bytes) > state.limits.object -> :object
      is_integer(write.size) and write.size > state.limits.object -> :object
      is_integer(write.size) and write.written + byte_size(bytes) > write.size -> :declared_length
      not is_integer(state.pressure_at) or now - state.pressure_at >= 5_000 -> :pressure_expired
      is_integer(state.pressure_deadline) and now >= state.pressure_deadline -> :pressure_expired
      not state.writable -> :pressure_paused
      not Budget.fits?(state.limits.quota, state.used, state.pending, additional) -> :quota
      true -> :headroom
    end
  end

  defp discard_write(state, ref) do
    case state.writes[ref] do
      nil ->
        state

      write ->
        :file.close(write.file)

        case File.rm_rf(write.path) do
          {:ok, _} ->
            Process.demonitor(ref, [:flush])

            Brady.Events.emit("brady.cache_write_finished",
              outcome: :abandoned,
              payload_chunks: div(write.written + @chunk - 1, @chunk)
            )

            %{
              state
              | writes: Map.delete(state.writes, ref),
                pending: state.pending - write.reserved
            }

          _ ->
            %{state | writable: false}
        end
    end
  end

  defp close_read(state, ref) do
    case state.reads[ref] do
      nil ->
        state

      read ->
        :file.close(read.file)
        Process.demonitor(ref, [:flush])
        %{state | reads: Map.delete(state.reads, ref)}
    end
  end

  # @cc [owner:ghuntley,label:capacity;recovery] brady-evict-only-below-floor
  # Eviction to zero MUST happen only under real pressure: pool headroom below
  # the 15 percent floor, unsafe guest-parent headroom, or invalid evidence.
  # A late observation, or the resume hysteresis band (15-20 percent free while
  # paused), MUST only deny writes and MUST keep every complete object.
  defp below_floor?(available, total, safe),
    do: not Budget.writable?(true, available, total, safe)

  defp evict(state, target) do
    active = MapSet.new(state.reads, fn {_, r} -> r.key end)

    state.entries
    |> Enum.sort_by(fn {_, e} -> e.access end)
    |> Enum.reduce_while(state, fn {key, entry}, acc ->
      cond do
        acc.used + acc.pending <= target ->
          {:halt, acc}

        MapSet.member?(active, key) ->
          {:cont, acc}

        true ->
          case File.rm_rf(object_path(state.root, key)) do
            {:ok, _} ->
              {:cont, %{acc | entries: Map.delete(acc.entries, key), used: acc.used - entry.cost}}

            _ ->
              {:cont, %{acc | writable: false}}
          end
      end
    end)
  end

  defp expire(state, key, now) do
    case state.entries[key] do
      %{metadata: metadata} = entry when is_integer(now) ->
        if (now < metadata["stored_at"] or now >= metadata["expires_at"]) and
             not Enum.any?(state.reads, fn {_, read} -> read.key == key end) do
          case File.rm_rf(object_path(state.root, key)) do
            {:ok, _} ->
              %{state | entries: Map.delete(state.entries, key), used: state.used - entry.cost}

            _ ->
              %{state | writable: false}
          end
        else
          state
        end

      _ ->
        state
    end
  end

  defp valid_key?(key), do: is_binary(key) and byte_size(key) == 64 and Regex.match?(@key, key)

  defp valid_size?(size, state),
    do: is_integer(size) and size >= 0 and size <= state.limits.object

  defp writable?(state),
    do:
      state.writable and state.used + state.pending <= state.limits.quota and
        is_integer(state.pressure_at) and
        System.monotonic_time(:millisecond) - state.pressure_at < 5_000 and
        (is_nil(state.pressure_deadline) or
           System.monotonic_time(:millisecond) < state.pressure_deadline)

  defp object_path(root, key), do: Path.join([root, "objects", binary_part(key, 0, 2), key])

  defp private_directory(path) do
    case File.mkdir(path) do
      :ok ->
        File.chmod(path, 0o700)

      {:error, :eexist} ->
        case File.lstat(path) do
          {:ok, %{type: :directory, mode: mode}} ->
            if Bitwise.band(mode, 0o077) == 0, do: :ok, else: :error

          _ ->
            :error
        end

      error ->
        error
    end
  end

  defp cleanup_temp(root) do
    path = Path.join(root, "tmp")
    with :ok <- private_directory(path), {:ok, _} <- File.rm_rf(path), do: private_directory(path)
  end

  defp create_write(path) do
    with :ok <- private_directory(path),
         {:ok, file} <-
           :file.open(String.to_charlist(Path.join(path, "body")), [
             :write,
             :binary,
             :raw,
             :exclusive
           ]) do
      {:ok, file}
    else
      _ ->
        File.rm_rf(path)
        :error
    end
  end

  defp encode_metadata(metadata, size) do
    with true <- valid_metadata?(metadata),
         encoded = JSON.encode!(%{"version" => 1, "size" => size, "metadata" => metadata}),
         true <- byte_size(encoded) <= @metadata_limit do
      {:ok, encoded}
    else
      _ -> :error
    end
  rescue
    _ -> :error
  end

  defp valid_metadata?(%{"stored_at" => stored, "expires_at" => expires} = metadata),
    do:
      is_integer(stored) and is_integer(expires) and expires > stored and map_size(metadata) <= 16

  defp valid_metadata?(_), do: false

  defp recover(state) do
    # Only fixed hexadecimal shards and keys are traversed. Unexpected data is
    # retained and disables startup rather than being adopted or removed.
    with {:ok, shards} <- File.ls(Path.join(state.root, "objects")),
         true <- length(shards) <= 256 do
      Enum.reduce_while(shards, {:ok, state}, fn shard, {:ok, acc} ->
        case recover_shard(acc, shard) do
          {:ok, next} -> {:cont, {:ok, next}}
          _ -> {:halt, :error}
        end
      end)
    else
      _ -> :error
    end
  end

  defp recover_shard(state, shard) do
    path = Path.join([state.root, "objects", shard])

    with true <- Regex.match?(~r/\A[0-9a-f]{2}\z/, shard),
         :ok <- private_directory(path),
         {:ok, keys} <- File.ls(path),
         true <- map_size(state.entries) + length(keys) <= state.max_entries do
      Enum.reduce_while(keys, {:ok, state}, fn key, {:ok, acc} ->
        case recover_entry(acc, shard, key) do
          {:ok, next} -> {:cont, {:ok, next}}
          _ -> {:halt, :error}
        end
      end)
    else
      _ -> :error
    end
  end

  defp recover_entry(state, shard, key) do
    with true <- valid_key?(key) and String.starts_with?(key, shard),
         path = object_path(state.root, key),
         :ok <- private_directory(path),
         {:ok, %{type: :regular, size: meta_size, links: 1}} <-
           File.lstat(Path.join(path, "metadata.json")),
         true <- meta_size <= @metadata_limit,
         {:ok, data} <- File.read(Path.join(path, "metadata.json")),
         {:ok, %{"version" => 1, "size" => size, "metadata" => metadata}} <- JSON.decode(data),
         true <- valid_size?(size, state) and valid_metadata?(metadata),
         {:ok, %{type: :regular, size: ^size, links: 1}} <- File.lstat(Path.join(path, "body")) do
      entry = %{metadata: metadata, size: size, cost: size + @overhead, access: state.clock}

      {:ok,
       %{
         state
         | entries: Map.put(state.entries, key, entry),
           used: state.used + entry.cost,
           clock: state.clock + 1
       }}
    else
      _ -> :error
    end
  end
end
