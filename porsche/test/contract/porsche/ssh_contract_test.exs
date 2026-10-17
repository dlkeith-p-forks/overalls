defmodule PorscheSshContractTest do
  use Covenant.Case, component: "porsche.ssh"

  @tag obligation: "porsche.ssh.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Porsche.SSH.Channel,
      Porsche.SSH.Display,
      Porsche.SSH.Input,
      Porsche.SSH.Output,
      Porsche.SSH.Proof
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end
end
