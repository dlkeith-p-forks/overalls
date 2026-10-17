defmodule GalileoAuthorizedProxyContractTest do
  use Covenant.Case, component: "galileo.authorized_proxy"

  @tag obligation: "galileo.authorized_proxy.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Galileo.Application,
      Galileo.Config,
      Galileo.Control,
      Galileo.Counter,
      Galileo.Credential,
      Galileo.Events,
      Galileo.HTTP,
      Galileo.Privacy,
      Galileo.SLO,
      Galileo.Strip,
      Galileo.Upstream
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end

  @tag obligation: "galileo.authorized_proxy.I2"
  test "strip only removes complete path segments" do
    assert Galileo.Strip.apply("/api/v3", "/api/v3/users") == "/users"
    assert Galileo.Strip.apply("/api/v3", "/api/v3") == "/"
    assert Galileo.Strip.apply("/api/v3", "/api/v3x/users") == "/api/v3x/users"
  end

  @tag obligation: "galileo.authorized_proxy.I3"
  test "prefix stripping handles absent and wildcard prefixes" do
    assert Galileo.Strip.apply(nil, "/users") == "/users"
    assert Galileo.Strip.apply("/api", "*") == "*"
    assert Galileo.Strip.apply("/api", "/apiary") == "/apiary"
    assert Galileo.Strip.apply("", "/users") == "/users"
    assert Galileo.Strip.apply("/api/", "/api/users") == "/users"
  end

  @tag obligation: "galileo.authorized_proxy.I4"
  test "SLO actor records outcomes" do
    {:ok, pid} = Galileo.SLO.start_link([])
    on_exit(fn -> if Process.alive?(pid), do: GenServer.stop(pid) end)
    GenServer.cast(pid, {:record, true, 10})
    GenServer.cast(pid, {:record, false, 20})
    Process.sleep(10)
    snapshot = GenServer.call(pid, :snapshot)
    assert snapshot.successes == 1
    assert snapshot.failures == 1
    assert snapshot.duration.sum_us == 30
  end
end
