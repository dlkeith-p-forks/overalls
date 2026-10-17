defmodule Brady.ConfigTest do
  use ExUnit.Case, async: true

  defp config do
    %{
      "version" => 1,
      "host_id" => "11111111-2222-3333-4444-555555555555",
      "issuer_cert_file" => "/run/credentials/brady/issuer.pem",
      "issuer_key_file" => "/run/credentials/brady/issuer.key",
      "upstream_ca_file" => "/etc/ssl/certs/ca-bundle.crt",
      "protected_cidrs" => ["8.8.8.0/24"],
      "tls_exceptions" => [%{"host" => "pinned.example", "port" => 443}],
      "cache_directory" => "/var/cache/brady",
      "cache_dataset" => "tank/brady-fixture",
      "cache_quota_bytes" => 100_000_000
    }
  end

  test "runtime retains protected ranges, exact exceptions and mandatory socket mark" do
    assert {:ok, cfg} = Brady.Config.validate(config())
    proxy = Brady.Config.proxy(cfg)
    refute Brady.Destination.allowed?({10, 1, 2, 3}, 443, proxy.destination_policy)
    refute Brady.Destination.allowed?({8, 8, 8, 8}, 443, proxy.destination_policy)
    assert MapSet.member?(proxy.tls_exceptions, {"pinned.example", 443})
    refute MapSet.member?(proxy.tls_exceptions, {"pinned.example", 8443})
    assert proxy.socket_options == [{:raw, 1, 36, <<0x42524145::native-unsigned-32>>}]
    assert proxy.attribution.({1, 1, 1, 1}).attribution == :unresolved
    assert cfg.limits.object == 10_000_000
  end

  test "malformed, secret-store and policy override configurations fail closed" do
    for bad <- [
          nil,
          [],
          %{},
          Map.put(config(), "socket_options", []),
          Map.put(config(), "issuer_key_file", "/nix/store/private-key"),
          Map.put(config(), "cache_directory", "/var/cache/../brady"),
          Map.put(config(), "cache_quota_bytes", 1),
          Map.put(config(), "protected_cidrs", ["10.1.0.0/8"]),
          Map.put(config(), "tls_exceptions", [%{"host" => "*.example", "port" => 443}]),
          Map.put(config(), "tls_exceptions", [
            %{"host" => "pinned.example", "port" => 443, "bypass" => true}
          ])
        ] do
      assert {:error, :invalid_configuration} = Brady.Config.validate(bad)
    end
  end
end
