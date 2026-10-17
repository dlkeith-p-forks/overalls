defmodule Lilly.Network.PrivateServicesTest do
  use ExUnit.Case, async: true
  alias Lilly.Network.{Config, Policy}
  @host "01234567-89ab-4def-8123-456789abcdef"

  test "service exception changes only namespace input/output" do
    {:ok, closed} = Config.new(@host, "eth0", [], "/var/lib/lilly/network", false, false)
    {:ok, enabled} = Config.new(@host, "eth0", [], "/var/lib/lilly/network", false, true)
    assert Policy.root(enabled) == Policy.root(closed)
    refute Policy.router(closed) =~ "ip daddr 169.254.254.1"
    policy = Policy.router(enabled)
    [_, input] = String.split(policy, "chain input", parts: 2)
    [input, output] = String.split(input, "chain output", parts: 2)
    assert input =~ ~s(ip saddr 10.10.0.0/16 ip daddr 169.254.254.1 tcp dport { 53, 443 })
    assert output =~ ~s(ip saddr 169.254.254.1 ip daddr 10.10.0.0/16 tcp sport { 53, 443 })

    assert elem(:binary.match(input, "ip daddr 169.254.254.1"), 0) <
             elem(:binary.match(input, "counter drop"), 0)

    assert elem(:binary.match(output, "ip daddr 10.10.0.0/16 tcp sport"), 0) <
             elem(:binary.match(output, "counter drop"), 0)

    assert policy =~ ~s(iifname "lv*" ip daddr 169.254.254.1 tcp dport { 53, 443 })
    assert policy =~ ~s(iifname "lv*" ip daddr 169.254.254.1 udp dport 53)

    assert policy =~
             ~s(ip saddr 169.254.254.1 tcp sport { 53, 443 } ct state established ct direction reply)

    [_, forwarding] = String.split(policy, "chain forward", parts: 2)
    [_, previous] = String.split(Policy.router(closed), "chain forward", parts: 2)
    assert forwarding == previous

    assert {:error, :invalid_network_configuration} =
             Config.new(@host, "eth0", [], "/var/lib/lilly/network", false, "true")
  end
end
