defmodule OverallsProtocol.IngressCatalogTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.IngressCatalog
  @id "00000000-0000-4000-8000-000000000001"

  property "catalog entries bind complete VM identities and positive execution numbers" do
    check all(
            epoch <- integer(1..9_223_372_036_854_775_807),
            generation <- integer(1..9_223_372_036_854_775_807)
          ) do
      item = entry(epoch, generation)

      assert {:ok, %{entries: [%{execution_epoch: ^epoch, generation: ^generation}]}} =
               IngressCatalog.decode(envelope([item]))

      assert {:error, :invalid_message} = IngressCatalog.decode(envelope([item, item]))

      for key <- Map.keys(item) do
        assert {:error, :invalid_message} =
                 IngressCatalog.decode(envelope([Map.delete(item, key)]))
      end

      assert {:error, :invalid_message} =
               IngressCatalog.decode(envelope([%{item | "execution_epoch" => 0}]))

      assert {:error, :invalid_message} =
               IngressCatalog.decode(
                 envelope([%{item | "label" => "vm-00000000000040008000000000000002"}])
               )
    end
  end

  test "entries carrying any extra key fail, including a retired certificate_id" do
    item = entry(1, 1)

    for {key, value} <- [{"certificate_id", nil}, {"certificate_id", @id}, {"authority", nil}] do
      assert {:error, :invalid_message} =
               IngressCatalog.decode(envelope([Map.put(item, key, value)]))
    end
  end

  test "empty catalogs are complete but oversized or augmented catalogs fail" do
    assert {:ok, %{entries: []}} = IngressCatalog.decode(envelope([]))

    assert {:error, :invalid_message} =
             IngressCatalog.decode(envelope(List.duplicate(entry(1, 1), 10_001)))

    assert {:error, :invalid_message} =
             IngressCatalog.decode(Map.put(envelope([]), "authority", true))

    for ttl <- [0, 30_001, nil, "5000"] do
      assert {:error, :invalid_message} =
               IngressCatalog.decode(put_in(envelope([]), ["catalog", "ttl"], ttl))
    end
  end

  test "catalog freshness accepts five seconds but refuses longer replies" do
    assert {:ok, %{ttl: 5_000}} = IngressCatalog.decode(envelope([]))

    for ttl <- [5_001, 30_000] do
      assert {:error, :invalid_message} =
               IngressCatalog.decode(put_in(envelope([]), ["catalog", "ttl"], ttl))
    end
  end

  defp entry(epoch, generation),
    do: %{
      "vm_id" => @id,
      "placement_id" => @id,
      "execution_epoch" => epoch,
      "generation" => generation,
      "label" => "vm-00000000000040008000000000000001"
    }

  defp envelope(entries),
    do: %{
      "version" => 1,
      "catalog" => %{
        "service_id" => @id,
        "host_id" => @id,
        "service_generation" => 1,
        "ttl" => 5000,
        "entries" => entries
      }
    }
end
