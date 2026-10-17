defmodule OverallsProtocol.TransferSSHTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias OverallsProtocol.TransferSSH

  property "canonical public keys and endpoints round trip without interpretation" do
    check all(key <- binary(length: 32), port <- integer(1..65_535)) do
      public = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, key::binary>>)
      assert TransferSSH.public_key?(public)

      for address <- ["lilly-1.example.net", "192.0.2.1"] do
        endpoint = %{"address" => address, "port" => port, "host_key" => public}
        assert {:ok, ^endpoint} = TransferSSH.endpoint(endpoint)
      end

      for invalid <- [public <> "\n", public <> " comment", "restrict " <> public, key] do
        refute TransferSSH.public_key?(invalid)
      end
    end
  end

  test "untrusted address and key syntax cannot expand SSH authority" do
    key = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 0::256>>)
    endpoint = %{"address" => "lilly.example", "port" => 2222, "host_key" => key}

    for address <- [
          "",
          "-oProxyCommand=x",
          "user@host",
          "a,b",
          "*.example",
          "a\nb",
          "[::1]",
          "::1",
          "2001:db8::1",
          "::ffff:192.0.2.1",
          "fe80::1%eth0",
          "2001:DB8::1",
          "127.01.0.1",
          "999.0.0.1",
          "a..b",
          "Host.example",
          "host.",
          String.duplicate("a", 64),
          <<255>>
        ] do
      assert {:error, :invalid_transfer_endpoint} =
               TransferSSH.endpoint(%{endpoint | "address" => address})
    end

    for changed <- [
          Map.put(endpoint, "user", "root"),
          Map.delete(endpoint, "host_key"),
          %{endpoint | "port" => 0},
          %{endpoint | "port" => 65_536},
          %{endpoint | "port" => "22"},
          %{endpoint | "host_key" => key <> " x"}
        ] do
      assert {:error, :invalid_transfer_endpoint} = TransferSSH.endpoint(changed)
    end
  end
end
