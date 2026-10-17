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

  @tag obligation: "porsche.ssh.I2"
  test "input handles CRLF and interrupt" do
    state = %Porsche.SSH.Input{}
    assert {:ok, state, ["hi"]} = Porsche.SSH.Input.feed(state, "hi\r")
    assert {:ok, _state, []} = Porsche.SSH.Input.feed(state, "\n")
    assert Porsche.SSH.Input.feed(%Porsche.SSH.Input{}, <<3>>) == :interrupt
  end
end
