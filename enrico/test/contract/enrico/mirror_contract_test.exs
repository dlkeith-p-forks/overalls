defmodule EnricoMirrorContractTest do
  use Covenant.Case, component: "enrico.mirror"

  @tag obligation: "enrico.mirror.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Enrico.Application,
      Enrico.Config,
      Enrico.Events,
      Enrico.Git,
      Enrico.HTTP,
      Enrico.Health,
      Enrico.Manager,
      Enrico.Privacy,
      Enrico.RefreshSupervisor,
      Enrico.SLO
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end
end
