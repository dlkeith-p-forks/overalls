defmodule Audi.Control.LinkHintTest do
  use ExUnit.Case, async: false

  test "hints wake only the readers registered for their kind" do
    assert Process.whereis(Audi.Control.Hints)
    {:ok, _} = Registry.register(Audi.Control.Hints, "gateway_catalog", nil)
    client = %{control: :unused}
    id = "123e4567-e89b-42d3-a456-426614174000"

    assert {:noreply, ^client} =
             Audi.Control.Link.handle_info(
               {:control, self(), {:hint, "gateway_catalog", id}},
               client
             )

    assert_receive {:control_hint, "gateway_catalog", ^id}

    for event <- [{:hint, "dns_snapshot", id}, :resync, {:connected, %{}}] do
      assert {:noreply, ^client} =
               Audi.Control.Link.handle_info({:control, self(), event}, client)
    end

    refute_receive {:control_hint, _, _}, 50
  end

  test "an authority hint reaches only the renewal workers registered for that VM or user" do
    vm = uuid()
    user = uuid()
    :ok = Audi.Authority.HintRenewal.register(vm: vm, user: user)
    client = %{control: :unused}

    for {kind, id} <- [{"vm", vm}, {"user", user}] do
      Audi.Control.Link.handle_info({:control, self(), {:hint, kind, id}}, client)
      assert_receive {:control_hint, ^kind, ^id}
    end

    Audi.Control.Link.handle_info({:control, self(), {:hint, "vm", uuid()}}, client)
    refute_receive {:control_hint, _, _}, 50
    assert Audi.Authority.HintRenewal.delay(30_000) == 15_000
    assert Audi.Authority.HintRenewal.delay(5000) == 1000
    assert Audi.Authority.HintRenewal.delay(0) == 1
  end

  @spec uuid() :: String.t()
  defp uuid do
    <<a::32, b::16, c::16, d::16, e::48>> = :crypto.strong_rand_bytes(16)

    :io_lib.format("~8.16.0b-~4.16.0b-~4.16.0b-~4.16.0b-~12.16.0b", [a, b, c, d, e])
    |> IO.iodata_to_binary()
  end
end
