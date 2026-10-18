defmodule Marshall.Terminal.PeerBudgetTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  alias Marshall.Terminal.PeerBudget

  test "one process owns one slot and another caller is refused at capacity" do
    budget = start_supervised!({PeerBudget, name: __MODULE__, limit: 1})
    assert {:ok, ^budget} = PeerBudget.acquire(budget)
    assert {:ok, ^budget} = PeerBudget.acquire(budget)
    assert PeerBudget.used(budget) == 1
    parent = self()
    start_supervised!({Task, fn -> send(parent, {:admission, PeerBudget.acquire(budget)}) end})
    assert_receive {:admission, {:error, :peer_capacity}}
    :ok = PeerBudget.release(budget)
    assert PeerBudget.used(budget) == 0
    assert {:ok, ^budget} = PeerBudget.acquire(budget)
  end

  test "owner death reclaims admission without an explicit release" do
    budget = start_supervised!({PeerBudget, name: __MODULE__, limit: 1})
    parent = self()

    owner =
      start_supervised!(
        {Task,
         fn ->
           {:ok, ^budget} = PeerBudget.acquire(budget)
           send(parent, :admitted)

           receive do
             :finish -> :ok
           end
         end}
      )

    assert_receive :admitted
    monitor = Process.monitor(owner)
    assert {:error, :peer_capacity} = PeerBudget.acquire(budget)
    send(owner, :finish)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :normal}
    assert reclaimed?(budget, System.monotonic_time(:millisecond) + 1000)
    assert {:ok, ^budget} = PeerBudget.acquire(budget)
  end

  # @cc [owner:ghuntley,label:verification;capacity;recovery] terminal-peer-budget-death-history
  # A saturated budget MUST refuse extra callers, then reclaim exactly the
  # slots of dead owners and admit that many replacements without a restart.
  property "generated mass owner death reclaims exactly the available slots", test_cases: 20 do
    check all(limit <- integer(2..8), deaths <- integer(1..limit), test_cases: 20) do
      budget = start_supervised!({PeerBudget, name: nil, limit: limit}, id: make_ref())
      parent = self()

      owners = for _ <- 1..limit, do: budget_owner(budget, parent)
      on_exit(fn -> Enum.each(owners, &Process.exit(&1, :kill)) end)

      for _ <- owners, do: assert_receive({:budget_owner, {:ok, ^budget}})
      assert PeerBudget.used(budget) == limit
      assert {:error, :peer_capacity} = PeerBudget.acquire(budget)

      {dead, living} = Enum.split(owners, deaths)
      monitors = Enum.map(dead, &Process.monitor/1)
      Enum.each(dead, &Process.exit(&1, :kill))

      for {owner, monitor} <- Enum.zip(dead, monitors),
          do: assert_receive({:DOWN, ^monitor, :process, ^owner, :killed})

      assert reclaimed_count?(budget, limit - deaths, System.monotonic_time(:millisecond) + 1000)
      replacements = for _ <- 1..deaths, do: budget_owner(budget, parent)
      on_exit(fn -> Enum.each(replacements, &Process.exit(&1, :kill)) end)
      for _ <- replacements, do: assert_receive({:budget_owner, {:ok, ^budget}})
      assert PeerBudget.used(budget) == limit
      assert {:error, :peer_capacity} = PeerBudget.acquire(budget)

      Enum.each(living ++ replacements, &Process.exit(&1, :kill))
      assert reclaimed_count?(budget, 0, System.monotonic_time(:millisecond) + 1000)
      assert {:ok, ^budget} = PeerBudget.acquire(budget)
      assert PeerBudget.used(budget) == 1
      assert :ok = PeerBudget.release(budget)
      assert reclaimed_count?(budget, 0, System.monotonic_time(:millisecond) + 1000)
    end
  end

  @spec budget_owner(pid(), pid()) :: pid()
  defp budget_owner(budget, parent) do
    spawn(fn ->
      send(parent, {:budget_owner, PeerBudget.acquire(budget)})

      receive do
        :finish -> :ok
      end
    end)
  end

  @spec reclaimed_count?(pid(), non_neg_integer(), integer()) :: boolean()
  defp reclaimed_count?(budget, expected, deadline) do
    case PeerBudget.used(budget) do
      ^expected ->
        true

      _ ->
        if System.monotonic_time(:millisecond) >= deadline do
          false
        else
          Process.sleep(1)
          reclaimed_count?(budget, expected, deadline)
        end
    end
  end

  @spec reclaimed?(pid(), integer()) :: boolean()
  defp reclaimed?(budget, deadline) do
    case PeerBudget.used(budget) do
      0 -> true
      _ -> System.monotonic_time(:millisecond) < deadline and reclaimed?(budget, deadline)
    end
  end
end
