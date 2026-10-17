defmodule Audi.DNS.SnapshotTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Audi.DNS.{Directory, Snapshot}
  @label "demo-0123456789abcdef0123456789abcdef"
  @zone "apps.example"

  test "neutral editor publications are explicit and cannot publish personal or malformed editor origins" do
    for label <- ["webview", "editor-" <> String.duplicate("a", 32)] do
      value =
        envelope()
        |> Map.put("routes", [%{"label" => label, "addresses" => ["192.0.2.1"], "ttl" => 5000}])

      assert {:ok, _} = Snapshot.decode(value, @zone, now())
    end

    for label <- [
          "e-invalid-" <> String.duplicate("a", 32),
          OverallsProtocol.EditorName.label(
            "00000000-0000-4000-8000-000000000001",
            "00000000-0000-4000-8000-000000000002"
          )
        ] do
      value =
        envelope()
        |> Map.put("routes", [%{"label" => label, "addresses" => ["192.0.2.1"], "ttl" => 5000}])

      assert {:error, :invalid_message} = Snapshot.decode(value, @zone, now())
    end
  end

  test "a 10,000-VM envelope is accepted but the combined route/proof inventory is bounded" do
    routes =
      for n <- 1..10_000 do
        label =
          "vm-" <>
            (n |> Integer.to_string(16) |> String.downcase() |> String.pad_leading(32, "0"))

        %{"label" => label, "addresses" => ["192.0.2.1"], "ttl" => 5000}
      end

    value = envelope() |> Map.merge(%{"routes" => routes, "proofs" => []})
    assert {:ok, snapshot} = Snapshot.decode(value, @zone, now())
    assert map_size(snapshot.entries) == 10_000

    # Both arrays are individually within the bound, but represent 10,001 VMs.
    assert {:error, :invalid_message} =
             Snapshot.decode(Map.put(value, "proofs", envelope()["proofs"]), @zone, now())
  end

  test "closed envelope binds zone and rejects duplicate, malformed and excessive data" do
    valid = envelope()
    route = hd(valid["routes"])
    proof = hd(valid["proofs"])

    invalid = [
      Map.put(valid, "extra", true),
      Map.put(valid, "zone", "other.example"),
      Map.put(valid, "revision", -1),
      Map.put(valid, "ttl", 5001),
      Map.put(valid, "routes", [route, route]),
      Map.put(valid, "proofs", [proof, proof]),
      Map.put(valid, "routes", List.duplicate(route, 10_001)),
      Map.put(valid, "proofs", List.duplicate(proof, 10_001))
    ]

    invalid =
      invalid ++
        for replacement <- [
              [],
              ["127.1"],
              ["2001:DB8::1"],
              ["2001:db8::1"],
              ["192.0.2.1", "192.0.2.1"],
              ["guest.example"],
              List.duplicate("192.0.2.1", 9)
            ] do
          Map.put(valid, "routes", [Map.put(route, "addresses", replacement)])
        end

    invalid =
      invalid ++
        for record <- [
              Map.put(route, "ttl", 5001),
              Map.put(route, "extra", true),
              Map.put(route, "label", "apps.dev-" <> String.duplicate("1", 32) <> ".inception"),
              Map.put(route, "label", "p3000." <> @label)
            ] do
          Map.put(valid, "routes", [record])
        end

    invalid =
      invalid ++
        for record <- [
              Map.put(proof, "proofs", ["bad"]),
              Map.put(proof, "ttl", 0),
              Map.put(proof, "extra", true)
            ] do
          Map.put(valid, "proofs", [record])
        end

    for value <- invalid do
      assert {:error, :invalid_message} = Snapshot.decode(value, @zone, now())
    end
  end

  property "every decoded deadline is bound to request start, even after response delay" do
    check all(ttl <- integer(1..5000), delay <- integer(0..6000)) do
      started = now() - delay

      value =
        envelope()
        |> Map.put("ttl", ttl)
        |> Map.put("routes", [%{"label" => @label, "addresses" => ["192.0.2.1"], "ttl" => ttl}])
        |> Map.put("proofs", [])

      case Snapshot.decode(value, @zone, started) do
        {:ok, snapshot} ->
          assert snapshot.expires_at == started + ttl
          assert snapshot.entries[@label <> "." <> @zone].expires_at == started + ttl
          assert delay < ttl

        {:error, :expired_response} ->
          assert started + ttl <= now()
      end
    end
  end

  test "per-route expiry cannot become NXDOMAIN or be revived by extending snapshot expiry" do
    directory = Audi.Test.DNSDirectory.start!([])
    value = envelope() |> put_in(["routes", Access.at(0), "ttl"], 1)
    assert {:ok, snapshot} = Snapshot.decode(value, @zone, now() - 100)
    assert :ok = Directory.publish(directory, 1, snapshot.entries, snapshot.expires_at)
    assert :stale = Directory.lookup(directory, @label <> "." <> @zone)

    assert {:ok, 1, %{challenges: [_]}} =
             Directory.lookup(directory, "_acme-challenge." <> @label <> "." <> @zone)

    assert :ok = Directory.publish(directory, 1, snapshot.entries, now() + 5000)
    assert :stale = Directory.lookup(directory, @label <> "." <> @zone)
    assert {:ok, 1, nil} = Directory.lookup(directory, "missing." <> @zone)
  end

  test "empty snapshots remove previous owners atomically and old revisions cannot restore them" do
    directory = Audi.Test.DNSDirectory.start!([])
    assert {:ok, first} = Snapshot.decode(envelope(), @zone, now())
    assert :ok = Directory.publish(directory, 1, first.entries, first.expires_at)
    empty = envelope() |> Map.merge(%{"revision" => 2, "routes" => [], "proofs" => []})
    assert {:ok, second} = Snapshot.decode(empty, @zone, now())
    assert :ok = Directory.publish(directory, 2, second.entries, second.expires_at)
    assert {:error, :stale} = Directory.publish(directory, 1, first.entries, first.expires_at)
    assert {:ok, 2, nil} = Directory.lookup(directory, @label <> "." <> @zone)
  end

  defp envelope do
    %{
      "version" => 1,
      "zone" => @zone,
      "revision" => 1,
      "ttl" => 5000,
      "routes" => [
        %{"label" => @label, "addresses" => ["192.0.2.1", "192.0.2.2"], "ttl" => 5000}
      ],
      "proofs" => [
        %{
          "label" => @label,
          "proofs" => [Base.url_encode64(<<0::256>>, padding: false)],
          "ttl" => 5000
        }
      ]
    }
  end

  defp now, do: System.monotonic_time(:millisecond)
end
