defmodule OverallsProtocol.InceptionControlTest do
  use ExUnit.Case, async: true
  alias OverallsProtocol.InceptionControl
  @id "11111111-1111-4111-8111-111111111111"

  test "parent discovery cannot change the offer namespace" do
    label = "vm-11111111111141118111111111111111"
    parent = %{"label" => label, "zone" => "apps.example", "origin" => "https://parent.example"}

    offer = %{
      "version" => 4,
      "host_id" => @id,
      "session_id" => @id,
      "epoch" => 1,
      "offer_id" => @id,
      "vm_id" => @id,
      "placement_id" => @id,
      "execution_epoch" => 1,
      "generation" => 1,
      "environment_generation" => 1,
      "label" => label,
      "zone" => "apps.example",
      "ttl_ms" => 5000,
      "public" => nil,
      "parent" => parent
    }

    assert {:ok, %{parent: ^parent}} = InceptionControl.offer(offer)
    assert {:ok, %{parent: nil}} = InceptionControl.offer(%{offer | "parent" => nil})

    for bad <- [
          Map.delete(offer, "parent"),
          Map.delete(offer, "public"),
          Map.delete(offer, "ttl_ms"),
          Map.put(offer, "address", "127.0.0.1"),
          offer |> Map.delete("public") |> Map.put("address", "127.0.0.1")
        ] do
      assert {:error, :invalid_message} = InceptionControl.offer(bad)
    end

    for bad <- [
          %{parent | "zone" => "other.example"},
          %{parent | "label" => "other-11111111111141118111111111111111"},
          %{parent | "origin" => "https://[::1]"},
          Map.put(parent, "port", 22)
        ] do
      assert {:error, :invalid_message} = InceptionControl.offer(%{offer | "parent" => bad})
    end
  end

  test "only exact versioned execution bindings can request an offer" do
    value = %{
      "version" => 4,
      "session_id" => @id,
      "epoch" => 1,
      "vm_id" => @id,
      "placement_id" => @id,
      "execution_epoch" => 2,
      "generation" => 3,
      "result" => nil
    }

    assert {:ok, %{execution_epoch: 2, generation: 3, result: nil}} =
             InceptionControl.request(value)

    for bad <- [
          Map.put(value, "version", 1),
          Map.put(value, "epoch", 0),
          Map.put(value, "address", "127.0.0.1"),
          Map.put(value, "vm_id", "invalid"),
          Map.delete(value, "placement_id"),
          Map.put(value, "result", %{}),
          Map.put(value, "result", %{"offer_id" => @id, "publication" => %{"records" => []}})
        ] do
      assert {:error, :invalid_message} = InceptionControl.request(bad)
    end
  end
end
