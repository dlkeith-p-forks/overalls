defmodule Ziggy.LeaseTest do
  use ExUnit.Case, async: true
  @request "11111111-1111-4111-8111-111111111111"

  test "blocked renewal cannot prevent cancellation of a blocked request" do
    tasks = start_supervised!({Task.Supervisor, []})

    owner =
      spawn(fn ->
        receive do
          :never -> :ok
        end
      end)

    ref = Process.monitor(owner)

    lease =
      start_supervised!(
        {Ziggy.Lease,
         owner: owner,
         tasks: tasks,
         request_id: @request,
         ttl_ms: 100,
         renewal_ms: 10,
         renew: fn ->
           receive do
             :never -> :ok
           end
         end}
      )

    lease_ref = Process.monitor(lease)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 1000
    assert_receive {:DOWN, ^lease_ref, :process, ^lease, :normal}, 1000
  end

  test "killed guardian retains its independent owner deadline" do
    tasks = start_supervised!({Task.Supervisor, []})
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    owner =
      spawn(fn ->
        receive do
          :never -> :ok
        end
      end)

    ref = Process.monitor(owner)

    {:ok, lease} =
      DynamicSupervisor.start_child(
        supervisor,
        {Ziggy.Lease,
         owner: owner,
         tasks: tasks,
         request_id: @request,
         ttl_ms: 100,
         renewal_ms: 90,
         renew: fn -> :ok end}
      )

    Process.exit(lease, :kill)
    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 1000
    assert DynamicSupervisor.count_children(supervisor).active == 0
  end

  test "normal completion does not restart the request guardian" do
    tasks = start_supervised!({Task.Supervisor, []})
    supervisor = start_supervised!({DynamicSupervisor, strategy: :one_for_one})

    {:ok, lease} =
      DynamicSupervisor.start_child(
        supervisor,
        {Ziggy.Lease,
         owner: self(),
         tasks: tasks,
         request_id: @request,
         ttl_ms: 100,
         renewal_ms: 90,
         renew: fn -> :ok end}
      )

    Ziggy.Lease.stop(lease)
    assert DynamicSupervisor.count_children(supervisor).active == 0
  end

  test "explicit authority revocation fences immediately" do
    tasks = start_supervised!({Task.Supervisor, []})

    owner =
      spawn(fn ->
        receive do
          :never -> :ok
        end
      end)

    ref = Process.monitor(owner)

    start_supervised!(
      {Ziggy.Lease,
       owner: owner,
       tasks: tasks,
       request_id: @request,
       ttl_ms: 30_000,
       renewal_ms: 1,
       renew: fn -> {:error, :revoked} end}
    )

    assert_receive {:DOWN, ^ref, :process, ^owner, :killed}, 1000
  end
end
