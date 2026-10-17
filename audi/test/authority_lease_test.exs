defmodule Audi.Authority.LeaseTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Audi.Authority.Lease
  @binding %{session_id: "s", placement_id: "p", execution_epoch: 3}

  property "network delay consumes grant lifetime instead of extending it" do
    check all(
            start <- integer(-1_000_000..1_000_000),
            ttl <- integer(-100..31_000),
            delay <- integer(-100..32_000)
          ) do
      result = Lease.new(@binding, start, ttl, start + delay)

      if ttl in 1..30_000 and delay >= 0 and delay < ttl do
        assert {:ok, lease} = result
        assert lease.expires_at == start + ttl
        assert lease.expires_at - (start + delay) <= 30_000 - delay
        refute Lease.active?(lease, start + ttl)
      else
        assert {:error, :invalid_grant} = result
      end
    end
  end

  property "a late renewal cannot resurrect an expired stream" do
    check all(ttl <- integer(1..5000), late <- integer(0..10_000)) do
      assert {:ok, lease} = Lease.new(@binding, -10_000, ttl, -10_000)
      now = -10_000 + ttl + late
      assert {:error, :expired} = Lease.renew(lease, @binding, now, 5000, now)
    end
  end

  test "renewal pins placement and epoch, and ignores reordered or replayed replies" do
    {:ok, lease} = Lease.new(@binding, 1000, 5000, 1100)
    {:ok, lease} = Lease.renew(lease, @binding, 2000, 5000, 2100)
    assert lease.expires_at == 7000
    assert {:error, :stale} = Lease.renew(lease, @binding, 1000, 5000, 2200)
    assert {:error, :stale} = Lease.renew(lease, @binding, 2000, 5000, 2200)

    for changed <- [%{@binding | placement_id: "q"}, %{@binding | execution_epoch: 4}] do
      assert {:error, :binding_changed} = Lease.renew(lease, changed, 3000, 5000, 3100)
    end
  end
end
