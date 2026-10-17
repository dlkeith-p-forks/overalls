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
end
