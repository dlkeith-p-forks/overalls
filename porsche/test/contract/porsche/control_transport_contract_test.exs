defmodule PorscheControlTransportContractTest do
  use Covenant.Case, component: "porsche.control_transport"

  @tag obligation: "porsche.control_transport.I1"
  test "declared modules compile and remain loadable" do
    modules = [Porsche.Client, Porsche.Connection, Porsche.Control.Link, Porsche.Runner]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end

  @tag obligation: "porsche.control_transport.I2"
  test "control client rejects unsafe origins and tokens" do
    assert {:ok, client} =
             Porsche.Client.new(
               "https://control.example",
               "porsche_gateway_" <> Base.url_encode64(<<0::256>>, padding: false)
             )

    assert client.origin == "https://control.example"

    assert {:error, :invalid_configuration} =
             Porsche.Client.new("http://control.example", "token")

    assert {:error, :invalid_configuration} =
             Porsche.Client.new(
               "https://[::1]",
               "porsche_gateway_" <> Base.url_encode64(<<0::256>>, padding: false)
             )
  end
end
