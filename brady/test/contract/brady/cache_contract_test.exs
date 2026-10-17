defmodule BradyCacheContractTest do
  use Covenant.Case, component: "brady.cache"

  @tag obligation: "brady.cache.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Brady.Attribution,
      Brady.Cache,
      Brady.Cache.Archive,
      Brady.Cache.Budget,
      Brady.Cache.Policy,
      Brady.Cache.Pressure,
      Brady.Cache.Range,
      Brady.Cache.Recovery,
      Brady.Cache.Runtime,
      Brady.Cache.Store
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end

  @tag obligation: "brady.cache.I2"
  test "range policy routes malformed and selects bounded ranges" do
    h = fn pairs -> Enum.map(pairs, fn {k, v} -> {k, v} end) end
    assert Brady.Cache.Range.select(h.([{"range", "bytes=bad"}]), [], 10) == :upstream
    assert Brady.Cache.Range.select(h.([{"range", "bytes=2-4"}]), [], 10) == {:partial, 2, 3}
  end
end
