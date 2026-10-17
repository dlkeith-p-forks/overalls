defmodule Audi.Test.WebConnector do
  @moduledoc false
  def open(%{port: port, owner: owner}, binding) do
    send(owner, {:guest_binding, binding})
    :gen_tcp.connect({127, 0, 0, 1}, port, [:binary, active: false, send_timeout: 1000], 1000)
  end
end
