defmodule OverallsProtocol.InceptionExchangeTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.InceptionExchange
  @id "11111111-1111-4111-8111-111111111111"
  @boot %{placement_id: @id, execution_epoch: 1, boot_challenge: String.duplicate("a", 64)}

  defp publication do
    %{
      "version" => 1,
      "binding" => Map.new(@boot, fn {key, value} -> {Atom.to_string(key), value} end),
      "request_id" => @id,
      "generation" => 1,
      "ttl_ms" => 5000,
      "porsche_host_key" => nil,
      "audi_host_key" => nil,
      "records" => [
        %{
          "label" => "control",
          "ready" => false,
          "proofs" => [Base.url_encode64(<<0::256>>, padding: false)]
        }
      ]
    }
  end

  test "DNS proof publication does not require service readiness or a host key" do
    value = publication()
    assert {:ok, bytes} = InceptionExchange.encode(value)
    assert {:ok, ^value} = InceptionExchange.verify(bytes, @boot, @id, 1)
    assert InceptionExchange.port() == 1028
    assert InceptionExchange.port() not in [1024, 1025, 1026]

    for boot <- [
          %{@boot | execution_epoch: 2},
          %{@boot | boot_challenge: String.duplicate("b", 64)}
        ] do
      assert {:error, :stale_inception_publication} =
               InceptionExchange.verify(bytes, boot, @id, 1)
    end

    assert {:error, :stale_inception_publication} = InceptionExchange.verify(bytes, @boot, @id, 2)

    assert {:error, :stale_inception_publication} =
             InceptionExchange.verify(bytes, @boot, "22222222-2222-4222-8222-222222222222", 1)
  end

  test "empty label is reserved for a proof-only child wildcard" do
    value = publication()
    [record] = value["records"]
    valid = Map.put(value, "records", [%{record | "label" => ""}])
    assert {:ok, _} = InceptionExchange.encode(valid)

    for invalid <- [
          %{record | "label" => "", "ready" => true},
          %{record | "label" => "", "proofs" => []}
        ] do
      assert {:error, :invalid_inception_publication} =
               InceptionExchange.encode(Map.put(value, "records", [invalid]))
    end
  end

  test "child cannot publish arbitrary DNS or forwarding authority" do
    value = publication()
    [record] = value["records"]

    for bad <- [
          Map.put(value, "version", 2),
          Map.delete(value, "ttl_ms"),
          Map.put(value, "ttl_ms", 0),
          Map.put(value, "ttl_ms", 5001),
          Map.put(value, "ttl_ms", true),
          Map.put(value, "token", "parent"),
          Map.put(value, "porsche_host_key", "bad"),
          Map.put(value, "records", [record, record]),
          Map.put(value, "records", List.duplicate(record, 257)),
          Map.put(value, "records", [Map.put(record, "address", "127.0.0.1")]),
          Map.put(value, "records", [Map.put(record, "label", "other.example")]),
          Map.put(value, "records", [Map.put(record, "proofs", [String.duplicate("x", 100)])])
        ] do
      assert {:error, :invalid_inception_publication} =
               InceptionExchange.decode(JSON.encode!(bad))
    end
  end

  property "arbitrary bounded bytes cannot escape the decoder" do
    check all(bytes <- binary(max_length: 300_000), max_runs: 30) do
      assert {:error, :invalid_inception_publication} = InceptionExchange.decode(bytes)
    end
  end
end
