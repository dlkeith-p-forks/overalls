defmodule Marshall.Control.PeachServiceTest do
  use ExUnit.Case, async: true

  alias Marshall.Control.Services.Peach

  test "uses a dedicated credential shape and refuses malformed requests" do
    assert :refused = Peach.authenticate("not-a-peach-credential")

    assert {:error, "invalid_request"} =
             Peach.handle_request("peach.snapshot", %{}, %{host_id: "host"})
  end

  test "is registered as a control service" do
    assert {:ok, Peach} = Marshall.Control.Service.fetch("peach")
  end
end
