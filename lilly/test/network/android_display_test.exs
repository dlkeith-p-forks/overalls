defmodule Lilly.Network.AndroidDisplayTest do
  use ExUnit.Case, async: true
  alias Lilly.Network.{AndroidDisplay, Config, Guest, Ingress, Policy}

  test "derives fixed display target for the current generation" do
    assert {:ok, guest} = Guest.new("11111111-1111-4111-8111-111111111111", :standard, 7)

    assert {:ok, target} =
             AndroidDisplay.target(guest, %{android_display: true, generation: 9}, 9)

    assert target.address == guest.address
    assert target.port == 5900
    assert target.generation == 9
  end

  test "rejects stale generations and absent capability" do
    assert {:ok, guest} = Guest.new("11111111-1111-4111-8111-111111111111", :standard, 7)

    assert {:error, :display_unavailable} =
             AndroidDisplay.target(guest, %{android_display: true, generation: 8}, 9)

    assert {:error, :display_unavailable} =
             AndroidDisplay.target(guest, %{android_display: false, generation: 9}, 9)
  end

  test "web ingress cannot select the display relay port" do
    for profile <- [:standard, :oss] do
      assert {:ok, guest} = Guest.new("11111111-1111-4111-8111-111111111111", profile, 7)

      assert {:error, :ingress_unavailable} =
               Ingress.target(guest, %{service: :web, port: 5900})
    end
  end

  test "only the display mark admits host connections to the relay port" do
    {:ok, enabled} =
      Config.new("af4bdc65-e17f-49ae-9bfb-cbe4cf0a4071", "eth0", [], "/var/lib/lilly", true)

    {:ok, disabled} =
      Config.new("af4bdc65-e17f-49ae-9bfb-cbe4cf0a4071", "eth0", [], "/var/lib/lilly")

    mark = Policy.android_display_mark()
    router = Policy.router(enabled)

    assert router =~ "meta mark #{mark} oifname \"lv*\""

    assert router =~
             "tcp dport 5900 ct state { new, established } ct mark set #{mark} counter accept"

    assert router =~
             "tcp dport != { 4444, 5900 } ct state { new, established } ct mark set #{Policy.ingress_mark(:web)}"

    refute router =~ "10.10.0.0/16 } tcp dport 5900"
    refute Policy.router(disabled) =~ "tcp dport 5900"
  end
end
