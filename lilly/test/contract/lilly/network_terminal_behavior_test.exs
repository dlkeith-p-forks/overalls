defmodule LillyNetworkTerminalBehaviorContractTest do
  use Covenant.Case, component: "lilly.network_terminal"

  @host "11111111-1111-4111-8111-111111111111"
  @placement "22222222-2222-4222-8222-222222222222"

  @tag obligation: "lilly.network_terminal.I2"
  test "network configuration rejects unsafe interfaces and canonicalizes protected ranges" do
    assert {:ok, config} =
             Lilly.Network.Config.new(
               @host,
               "eth0",
               ["10.0.0.0/8", "10.0.0.0/8"],
               "/var/lib/lilly"
             )

    assert config.protected == ["10.0.0.0/8"]
    assert config.namespace =~ "lilly-"

    assert {:error, :invalid_network_configuration} =
             Lilly.Network.Config.new(@host, "eth;rm", [], "/var/lib/lilly")

    refute Lilly.Network.Config.cidr?("10.0.0.1/8")
  end

  @tag obligation: "lilly.network_terminal.I3"
  test "flow labels bind host and placement incarnation" do
    assert {:ok, first} =
             Lilly.Network.FlowLabel.token(@host, %{
               placement_id: @placement,
               execution_epoch: 1,
               generation: 1
             })

    assert {:ok, second} =
             Lilly.Network.FlowLabel.token(@host, %{
               placement_id: @placement,
               execution_epoch: 1,
               generation: 2
             })

    assert first != second

    assert {:error, :invalid_flow_identity} =
             Lilly.Network.FlowLabel.token("bad", %{
               placement_id: @placement,
               execution_epoch: 1,
               generation: 1
             })
  end
end
