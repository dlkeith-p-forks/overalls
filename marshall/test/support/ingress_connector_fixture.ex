defmodule Marshall.IngressConnectorFixture do
  @moduledoc false
  def open({port, guardian}, %{service: :ssh, port: 22}) do
    with {:ok, socket} <- :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false], 1000),
         do: {:ok, socket, guardian}
  end
end
