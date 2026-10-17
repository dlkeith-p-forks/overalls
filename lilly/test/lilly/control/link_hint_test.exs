defmodule Lilly.Control.LinkHintTest do
  use ExUnit.Case, async: false

  test "a host_commands hint asks the runtime to exchange; other events do not" do
    Process.register(self(), Lilly.Control.Runtime)
    client = %{control: :unused}
    id = "123e4567-e89b-42d3-a456-426614174000"

    assert {:noreply, ^client} =
             Lilly.Control.Link.handle_info(
               {:control, self(), {:hint, "host_commands", id}},
               client
             )

    assert_receive :commands_hinted

    for event <- [{:hint, "host", id}, :resync, {:connected, %{}}] do
      assert {:noreply, ^client} =
               Lilly.Control.Link.handle_info({:control, self(), event}, client)
    end

    refute_receive :commands_hinted, 50
  after
    if Process.whereis(Lilly.Control.Runtime) == self(),
      do: Process.unregister(Lilly.Control.Runtime)
  end
end
