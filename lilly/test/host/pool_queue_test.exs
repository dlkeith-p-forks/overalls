defmodule Lilly.Host.PoolQueueTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Lilly.Host.PoolQueue

  @rank %{observe: 0, mutate: 1, upkeep: 2}

  defp directory, do: "/pool-queue-test/" <> Integer.to_string(System.unique_integer([:positive]))

  defp queued(directory) do
    case :sys.get_state(PoolQueue).lanes[directory] do
      nil -> 0
      lane -> Enum.sum(for {_priority, queue} <- lane.queues, do: :queue.len(queue))
    end
  end

  defp eventually(fun, attempts \\ 400) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not reached")
      true -> Process.sleep(5) && eventually(fun, attempts - 1)
    end
  end

  # A waiter that reports its grant and holds the turn until told to leave.
  defp waiter(parent, directory, index, priority, wait_ms) do
    spawn(fn ->
      case PoolQueue.enter(directory, priority, wait_ms) do
        {:ok, turn} ->
          send(parent, {:granted, index, self()})

          receive do
            :leave -> PoolQueue.leave(directory, turn)
          end

        {:error, :busy} ->
          send(parent, {:busy, index})
      end
    end)
  end

  # @cc [owner:ghuntley,label:verification;concurrency] pool-turns-order-oracle
  # Generated arrival sequences MUST be granted one at a time, in priority
  # order and FIFO within a priority, matching an independent sort of the
  # arrivals; the queue is never asked to order against itself.
  property "turns are exclusive, priority-ordered and FIFO within a priority" do
    check all(
            priorities <- list_of(member_of([:observe, :mutate, :upkeep]), max_length: 12),
            max_runs: 25
          ) do
      directory = directory()
      parent = self()
      {:ok, holder} = PoolQueue.enter(directory, :mutate, 0)

      for {priority, index} <- Enum.with_index(priorities) do
        waiter(parent, directory, index, priority, 10_000)
        eventually(fn -> queued(directory) == index + 1 end)
      end

      expected =
        priorities
        |> Enum.with_index()
        |> Enum.sort_by(fn {priority, index} -> {@rank[priority], index} end)
        |> Enum.map(&elem(&1, 1))

      :ok = PoolQueue.leave(directory, holder)

      granted =
        for _ <- expected do
          assert_receive {:granted, index, pid}, 2000
          refute_receive {:granted, _, _}, 20
          send(pid, :leave)
          index
        end

      assert granted == expected
      eventually(fn -> is_nil(:sys.get_state(PoolQueue).lanes[directory]) end)
    end
  end

  test "a zero wait never queues and an expired wait leaves without a grant" do
    directory = directory()
    {:ok, holder} = PoolQueue.enter(directory, :mutate, 0)
    assert {:error, :busy} = PoolQueue.enter(directory, :observe, 0)
    assert queued(directory) == 0

    waiter(self(), directory, 1, :mutate, 50)
    assert_receive {:busy, 1}, 2000
    assert queued(directory) == 0
    refute PoolQueue.waiting?(directory)

    :ok = PoolQueue.leave(directory, holder)
    eventually(fn -> is_nil(:sys.get_state(PoolQueue).lanes[directory]) end)
    assert {:ok, turn} = PoolQueue.enter(directory, :upkeep, 0)
    :ok = PoolQueue.leave(directory, turn)
  end

  test "a holder or waiter that exits passes or forfeits its turn" do
    directory = directory()
    parent = self()

    holder =
      spawn(fn ->
        {:ok, _turn} = PoolQueue.enter(directory, :mutate, 0)
        send(parent, :holding)

        receive do
          :never -> :ok
        end
      end)

    assert_receive :holding, 2000
    doomed = waiter(parent, directory, 1, :observe, 10_000)
    eventually(fn -> queued(directory) == 1 end)
    waiter(parent, directory, 2, :upkeep, 10_000)
    eventually(fn -> queued(directory) == 2 end)
    assert PoolQueue.waiting?(directory)

    Process.exit(doomed, :kill)
    eventually(fn -> queued(directory) == 1 end)
    Process.exit(holder, :kill)
    assert_receive {:granted, 2, pid}, 2000
    refute_receive {:granted, 1, _}, 50
    send(pid, :leave)
    eventually(fn -> is_nil(:sys.get_state(PoolQueue).lanes[directory]) end)
  end
end
