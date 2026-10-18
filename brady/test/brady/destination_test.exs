defmodule Brady.DestinationTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Brady.Destination

  property "all guest/private sources remain denied as proxy destinations" do
    {:ok, policy} = Destination.policy([])

    b = draw("b", integer(0..255))
    c = draw("c", integer(0..255))
    port = draw("port", integer(1..65535))

    for ip <- [
          {10, b, c, 1},
          {127, b, c, 1},
          {192, 168, b, c},
          {169, 254, b, c},
          {172, 16, b, c}
        ] do
      refute Destination.allowed?(ip, port, policy)
    end
  end

  test "public protected networks and all IPv6 stay denied" do
    {:ok, policy} = Destination.policy(["8.8.8.0/24"])
    refute Destination.allowed?({8, 8, 8, 8}, 443, policy)
    assert Destination.allowed?({1, 1, 1, 1}, 443, policy)
    refute Destination.allowed?({0, 0, 0, 0, 0, 0, 0, 1}, 443, policy)
    assert {:error, :invalid_policy} = Destination.policy(["8.8.8.8/24"])
  end

  test "authority cannot retarget a connection or smuggle userinfo and delimiters" do
    assert {:ok, "example.com", 8443} = Destination.authority("EXAMPLE.com:8443", 443)

    for value <- [
          "user@example.com",
          "example.com:0",
          "example.com:443:80",
          "example.com/secret",
          "example.com\r\n",
          "-example.com"
        ] do
      assert {:error, :invalid_authority} = Destination.authority(value, 443)
    end

    resolver = fn "example.com" -> {:ok, [{8, 8, 8, 8}]} end
    assert Destination.matches?("example.com", 443, {{8, 8, 8, 8}, 443}, resolver)
    refute Destination.matches?("example.com", 443, {{1, 1, 1, 1}, 443}, resolver)
    refute Destination.matches?("example.com", 80, {{8, 8, 8, 8}, 443}, resolver)

    refute Destination.matches?("example.com", 443, {{8, 8, 8, 8}, 443}, fn _ ->
             {:error, :timeout}
           end)
  end

  # Regression (production, 2026-09-28): guests and Brady resolve rotating
  # names such as github.com through different public resolvers and receive
  # different addresses. HTTPS admission MUST NOT depend on that agreement;
  # plain HTTP authority still MUST resolve to the original destination.
  property "HTTPS admits any resolver view while HTTP requires the original address" do
    a = draw("a", integer(1..223))
    b = draw("b", integer(0..255))
    dialled = draw("dialled", integer(1..254))
    resolved = draw("resolved", integer(1..254))
    port = draw("port", member_of([80, 443, 8443]))
    resolver_result = draw("resolver_result", member_of([:agree, :disagree, :error]))
    destination = {{a, b, 0, dialled}, port}

    resolver = fn "github.com" ->
      case resolver_result do
        :agree -> {:ok, [{a, b, 0, dialled}]}
        :disagree -> {:ok, [{a, b, 1, resolved}]}
        :error -> {:error, :timeout}
      end
    end

    assert Destination.acceptable?(:https, "github.com", port, destination, resolver)

    assert Destination.acceptable?(:http, "github.com", port, destination, resolver) ==
             (resolver_result == :agree)

    # Port and hostname validity still bind HTTPS admission.
    refute Destination.acceptable?(:https, "github.com", port + 1, destination, resolver)

    for invalid <- ["", "-bad.example", "a..b", "exa mple.com", "Example.COM."] do
      refute Destination.acceptable?(:https, invalid, port, destination, resolver)
    end
  end
end
