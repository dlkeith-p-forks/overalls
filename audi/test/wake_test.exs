defmodule Audi.WakeTest do
  use ExUnit.Case, async: false
  @vm "11111111-1111-4111-8111-111111111111"

  # @cc [owner:ghuntley,label:verification;recovery] wake-wait-retains-original-owner
  # Repeated capacity waits MUST retain one caller without consuming queued
  # application bytes; only fresh ready authority may return its final grant.
  test "renewing authorization keeps the original waiter beyond individual leases" do
    key = {__MODULE__, make_ref()}
    Process.put(key, 0)
    send(self(), {:application_bytes, <<1, 2, 3>>})
    started = System.monotonic_time(:millisecond)

    assert {:ok, %{ready: true}} =
             Audi.Wake.await(fn ->
               attempt = Process.get(key)
               Process.put(key, attempt + 1)

               if attempt < 8,
                 do: {:pending, %{vm_id: @vm, ttl: 100, retry_after_ms: 25}},
                 else: {:ok, %{ready: true}}
             end)

    assert System.monotonic_time(:millisecond) - started >= 200
    assert_receive {:application_bytes, <<1, 2, 3>>}
    assert Process.delete(key) == 9
  end

  test "fresh denial ends a wait instead of retrying it" do
    key = {__MODULE__, make_ref()}
    Process.put(key, false)

    assert {:error, :forbidden} =
             Audi.Wake.await(fn ->
               if Process.get(key),
                 do: {:error, :forbidden},
                 else:
                   (
                     Process.put(key, true)
                     {:pending, %{vm_id: @vm, ttl: 200, retry_after_ms: 1}}
                   )
             end)

    Process.delete(key)
    assert Audi.Wake.Waiters.acquire() == :ok
    assert Audi.Wake.Waiters.release() == :ok
  end

  test "a pending receipt cannot switch machine identity" do
    key = {__MODULE__, make_ref()}
    Process.put(key, 0)

    assert {:error, :binding_mismatch} =
             Audi.Wake.await(fn ->
               count = Process.get(key)
               Process.put(key, count + 1)
               id = if count == 0, do: @vm, else: "22222222-2222-4222-8222-222222222222"
               {:pending, %{vm_id: id, ttl: 200, retry_after_ms: 1}}
             end)

    Process.delete(key)
  end

  test "the independent authorization deadline kills an owner blocked in its next request" do
    parent = self()

    {owner, monitor} =
      spawn_monitor(fn ->
        Audi.Wake.await(fn ->
          if Process.get(:pending_authorized) do
            send(parent, {:blocked, self()})

            receive do
              :never -> {:error, :transport_error}
            end
          else
            Process.put(:pending_authorized, true)
            {:pending, %{vm_id: @vm, ttl: 120, retry_after_ms: 1}}
          end
        end)
      end)

    assert_receive {:blocked, ^owner}
    :erlang.suspend_process(owner)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}, 1000
  end

  test "the waiting budget is bounded and owner death returns its slots" do
    parent = self()

    owners =
      for _ <- 1..128 do
        spawn_monitor(fn ->
          :ok = Audi.Wake.Waiters.acquire()
          send(parent, {:acquired, self()})

          receive do
            :release -> Audi.Wake.Waiters.release()
          end
        end)
      end

    on_exit(fn -> Enum.each(owners, fn {owner, _} -> Process.exit(owner, :kill) end) end)
    for {owner, _} <- owners, do: assert_receive({:acquired, ^owner}, 1000)
    assert {:error, :capacity} = Audi.Wake.Waiters.acquire()
    for {owner, _} <- owners, do: Process.exit(owner, :kill)

    for {owner, monitor} <- owners,
        do: assert_receive({:DOWN, ^monitor, :process, ^owner, :killed})

    assert :ok = acquire_until(100)
    assert :ok = Audi.Wake.Waiters.release()
  end

  @spec acquire_until(non_neg_integer()) :: :ok | {:error, :capacity}
  defp acquire_until(0), do: {:error, :capacity}

  defp acquire_until(attempts) do
    case Audi.Wake.Waiters.acquire() do
      :ok ->
        :ok

      {:error, :capacity} ->
        Process.sleep(5)
        acquire_until(attempts - 1)
    end
  end
end
