defmodule Lilly.Host.Storage do
  @moduledoc "OS serialization of pool snapshots with disk creation, deletion and ownership changes."
  require Lilly.Events
  alias Lilly.Host.{Lock, Pool, PoolQueue}
  # @cc [owner:ghuntley,label:recovery] pool-lock-always-released
  # locked/2..4 MUST execute the callback only while holding both a PoolQueue
  # turn and the pool mutation lock, and release both on normal return and on
  # callback failure; an expired wait or unavailable ownership returns
  # storage_busy without running the callback. Mutations default to a
  # one-second wait; create preparation may wait up to 30 s for its turn. In a
  # BEAM that runs no PoolQueue the native lock is the only contention point
  # and its retry window stays at most two seconds.
  # Observations MUST explicitly use a short wait and report contention as
  # unavailable.
  @spec locked(Pool.t(), (-> term())) :: term()
  @spec locked(Pool.t(), (-> term()), 0..30_000) :: term()
  @spec locked(Pool.t(), (-> term()), 0..30_000, section()) :: term()
  def locked(pool, fun, wait_ms \\ 1000, kind \\ :other)
      when wait_ms in 0..30_000 and is_function(fun, 0) and is_atom(kind) do
    case turn(pool, kind, wait_ms, nil, fn _turn -> {fun.(), 1} end) do
      {:ran, result} -> result
      :busy -> {:error, :storage_busy}
    end
  end

  @batch_max 16

  # @cc [owner:ghuntley,label:concurrency;recovery] pool-batch-flat-combining
  # combine/5 MUST run `batch` only while holding a turn and the pool lock, over
  # this caller's item followed by at most 15 queued items of the same kind, in
  # queue order. `batch` returns exactly one result per item, in order; every
  # taken waiter MUST receive exactly its own result, or storage_busy when the
  # batch did not run (lock unavailable or `batch` raised). A caller answered
  # by another holder returns that holder's result for its item.
  @spec combine(Pool.t(), section(), item, ([item, ...] -> [result]), 0..30_000) ::
          result | {:error, :storage_busy}
        when item: term(), result: term()
  def combine(pool, kind, item, batch, wait_ms)
      when wait_ms in 0..30_000 and is_function(batch, 1) and is_atom(kind) do
    directory = Path.join(pool.path, ".lilly-storage")

    run = fn turn ->
      taken = if turn == :unqueued, do: [], else: PoolQueue.take(directory, kind, @batch_max - 1)

      try do
        [own | others] = batch.([item | Enum.map(taken, &elem(&1, 1))])

        if length(others) != length(taken),
          do: raise(ArgumentError, "batch returned the wrong number of results")

        Enum.zip_with(taken, others, fn {from, _item}, result ->
          PoolQueue.answer(from, result)
        end)

        {own, length(taken) + 1}
      rescue
        error ->
          Enum.each(taken, fn {from, _item} ->
            PoolQueue.answer(from, {:error, :storage_busy})
          end)

          reraise error, __STACKTRACE__
      end
    end

    case turn(pool, kind, wait_ms, {kind, item}, run) do
      {:ran, result} -> result
      {:combined, result} -> result
      :busy -> {:error, :storage_busy}
    end
  end

  # One turn, then the native pool lock, then `fun`; both always released.
  defp turn(pool, kind, wait_ms, combine, fun) do
    started = System.monotonic_time(:millisecond)
    directory = Path.join(pool.path, ".lilly-storage")

    case PoolQueue.enter(directory, priority(kind), wait_ms, combine) do
      {:ok, turn} ->
        try do
          # The turn holder is normally the only contender; the native retry
          # window only absorbs a lock still held by work outside the queue. A
          # BEAM without a queue polls the native lock for at most two seconds.
          remaining = max(0, min(2000, started + wait_ms - System.monotonic_time(:millisecond)))

          case acquire(directory, System.monotonic_time(:millisecond) + remaining) do
            {:ok, port} ->
              acquired = System.monotonic_time(:millisecond)
              items = :counters.new(1, [])
              :counters.put(items, 1, 1)

              try do
                {result, count} = fun.(turn)
                :counters.put(items, 1, count)
                {:ran, result}
              after
                Lock.release(port)

                section(
                  pool,
                  kind,
                  :acquired,
                  acquired - started,
                  System.monotonic_time(:millisecond) - acquired,
                  :counters.get(items, 1)
                )
              end

            _ ->
              busy(pool, kind, started)
          end
        after
          PoolQueue.leave(directory, turn)
        end

      {:combined, result} ->
        {:combined, result}

      {:error, :busy} ->
        busy(pool, kind, started)
    end
  end

  defp busy(pool, kind, started) do
    section(pool, kind, :busy, System.monotonic_time(:millisecond) - started, 0, 1)
    :busy
  end

  # Capacity snapshots are served first so reports stay fresh during bursts;
  # everything else is creation, deletion, transfer or template work.
  @spec priority(section()) :: PoolQueue.priority()
  defp priority(:snapshot), do: :observe
  defp priority(_kind), do: :mutate

  @typedoc "Diagnostic kind of a pool-locked section (ADR-0176 baseline)."
  @type section ::
          :prepare
          | :ready
          | :delete
          | :snapshot
          | :template_reserve
          | :template_create
          | :resize
          | :other

  @slow_section_ms 500

  # @cc [owner:ghuntley,label:observability] pool-section-diagnostics
  # Every busy acquisition, every batch of more than one item and every pool
  # section whose wait plus hold reaches 500 ms MUST emit lilly.pool_section
  # with only the pool id, the section kind, the outcome, the two durations and
  # the item count, after the lock is released; faster single-item sections
  # emit nothing. Diagnostics MUST NOT change lock semantics.
  defp section(pool, kind, outcome, wait_ms, hold_ms, items) do
    if outcome == :busy or items > 1 or wait_ms + hold_ms >= @slow_section_ms do
      Lilly.Events.emit("lilly.pool_section",
        pool_id: pool.id,
        kind: kind,
        outcome: outcome,
        wait_ms: wait_ms,
        hold_ms: hold_ms,
        items: items
      )
    end

    :ok
  end

  # @cc [owner:ghuntley,label:recovery;concurrency] pool-acquisition-retry-does-not-repeat-effects
  # Acquisition MUST wait once, in hostd's FIFO queue for the pool inode, for
  # the remaining window, before ownership and before the callback; the
  # window never restarts. Callback results, exceptions and uncertain
  # acquisition MUST NOT be retried. An explicit zero window MUST preserve a
  # single acquisition attempt.
  defp acquire(directory, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    Lock.await(directory, min(remaining, 120_000))
  end
end
