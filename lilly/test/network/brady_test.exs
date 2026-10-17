defmodule Lilly.Network.BradyTest do
  use ExUnit.Case, async: true
  alias Lilly.Network.{Config, Policy}
  @host "11111111-1111-4111-8111-111111111111"
  @proxy %{
    "uid" => 991,
    "http_ports" => [80, 8080],
    "https_ports" => [443],
    "dns" => ["1.1.1.1", "9.9.9.9"]
  }

  test "proxy configuration rejects injection, root identity, overlapping ports and extra fields" do
    for invalid <- [
          Map.put(@proxy, "uid", 0),
          Map.put(@proxy, "http_ports", ["80; accept"]),
          Map.put(@proxy, "https_ports", [80]),
          Map.put(@proxy, "dns", ["1.1.1.1; accept"]),
          Map.put(@proxy, "extra", true)
        ] do
      assert {:error, :invalid_network_configuration} =
               Config.new(@host, "eth0", [], "/var/lib/lilly/network", false, false, invalid)
    end
  end

  test "interception and UDP restrictions preserve ingress and protected-address barriers" do
    {:ok, config} =
      Config.new(@host, "eth0", ["8.8.8.0/24"], "/var/lib/lilly/network", true, false, @proxy)

    rules = Policy.router(config)
    assert rules =~ "tproxy ip to :15080"
    assert rules =~ "tproxy ip to :15443"
    assert rules =~ "tcp dport { 80, 8080, 443 } counter drop"
    assert rules =~ "udp counter reject with icmpx type port-unreachable"
    assert rules =~ "meta skuid 991 ip daddr @blocked oifname \"uplink\" counter drop"
    assert rules =~ "8.8.8.0/24"
    assert rules =~ Integer.to_string(Policy.ingress_mark(:ssh))
    refute Policy.brady_mark() in [Policy.ingress_mark(:ssh), Policy.ingress_mark(:web)]
  end

  test "disabled deployment retains existing egress policy" do
    {:ok, config} = Config.new(@host, "eth0", [], "/var/lib/lilly/network")
    refute Policy.router(config) =~ "tproxy"
    refute Policy.router(config) =~ "port-unreachable"
  end
end
