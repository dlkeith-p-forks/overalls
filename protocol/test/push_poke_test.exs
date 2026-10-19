defmodule OverallsProtocol.PushPokeTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.PushPoke

  # Shared with Mila's Dart decryptor and the iOS/Android extensions.
  @vectors Path.expand("fixtures/push_pokes.json", __DIR__)
  @external_resource @vectors

  @spec vectors() :: map()
  defp vectors, do: @vectors |> File.read!() |> JSON.decode!()

  @spec hex(String.t()) :: binary()
  defp hex(value), do: Base.decode16!(value, case: :lower)

  test "every valid vector seals to the exact bytes and opens to its payload" do
    %{"version" => 1, "valid" => valid} = vectors()
    assert length(valid) >= 2

    for vector <- valid do
      device_private = hex(vector["device_private"])
      device_public = hex(vector["device_public"])
      assert PushPoke.public_key(device_private) == device_public, vector["name"]

      %{"kind" => kind, "route" => route, "v" => 1} = JSON.decode!(vector["plaintext"])
      payload = %{kind: String.to_existing_atom(kind), route: route}

      assert {:ok, vector["plaintext"]} ==
               PushPoke.encode_plaintext(payload.kind, payload.route, vector["host"])

      assert {:ok, vector["poke"]} ==
               PushPoke.seal(payload, device_public, vector["host"],
                 ephemeral_private: hex(vector["ephemeral_private"]),
                 nonce: hex(vector["nonce"])
               ),
             vector["name"]

      assert {:ok, ^payload} = PushPoke.open(vector["poke"], device_private, vector["host"])
    end
  end

  test "every invalid vector is refused with its documented reason" do
    %{"invalid" => invalid} = vectors()
    assert length(invalid) >= 5

    for vector <- invalid do
      reason = String.to_existing_atom(vector["reason"])

      assert {:error, ^reason} =
               PushPoke.open(vector["poke"], hex(vector["device_private"]), vector["host"]),
             vector["name"]
    end
  end

  test "seal refuses content outside the closed kind and canonical routes" do
    {public, _private} = PushPoke.generate_key_pair()
    host = "control.example.test"
    machine = "2f0b8f8e-3c1d-4a8e-9b3e-0c6f1d2a7b11"

    assert {:ok, _} =
             PushPoke.seal(%{kind: :needs_input, route: "/machines/" <> machine}, public, host)

    for payload <- [
          %{kind: :prompt, route: "/machines"},
          %{kind: :needs_input, route: "/machines/not-a-uuid"},
          %{kind: :needs_input, route: "machines"},
          %{kind: :needs_input, route: "/machines?token=secret"},
          %{kind: :needs_input, route: "/machines", text: "hello"},
          %{kind: "needs_input", route: "/machines"}
        ] do
      assert {:error, :invalid_payload} = PushPoke.seal(payload, public, host), inspect(payload)
    end

    assert {:error, :invalid_key} =
             PushPoke.seal(%{kind: :needs_input, route: "/threads"}, <<1>>, host)

    assert {:error, :invalid_host} =
             PushPoke.seal(%{kind: :needs_input, route: "/threads"}, public, "Bad Host")

    assert {:error, :invalid_payload} =
             PushPoke.seal(%{kind: :needs_input, route: "/threads"}, public, host, nonce: <<1>>)
  end

  test "malformed input never raises" do
    {_public, private} = PushPoke.generate_key_pair()

    for poke <- ["", "!!!", "AQ", String.duplicate("A", 4096), <<255, 0>>] do
      assert {:error, _} = PushPoke.open(poke, private, "control.example.test")
    end

    assert {:error, :encoding} = PushPoke.open(nil, private, "control.example.test")
    assert {:error, :encoding} = PushPoke.open("AQ", <<1, 2>>, "control.example.test")
  end

  test "an encoded poke never exceeds the documented maximum length" do
    {public, _} = PushPoke.generate_key_pair()
    host = String.duplicate("a", 63) <> ".example.test"

    route =
      "/machines/2f0b8f8e-3c1d-4a8e-9b3e-0c6f1d2a7b11/threads/7a1c0e44-91f2-4d1e-8a5b-3e2f6c9d0a12"

    assert {:ok, poke} = PushPoke.seal(%{kind: :needs_input, route: route}, public, host)
    assert byte_size(poke) <= PushPoke.maximum_encoded_length()
  end

  @spec route_gen() :: Hegel.Gen.t()
  defp route_gen do
    uuid = map(binary(16, 16), &uuid/1)

    one_of([
      constant("/machines"),
      constant("/threads"),
      constant("/settings"),
      map(uuid, &("/machines/" <> &1)),
      map(uuid, &("/threads/" <> &1)),
      map(tuple([uuid, uuid]), fn {m, t} -> "/machines/" <> m <> "/threads/" <> t end)
    ])
  end

  @spec uuid(binary()) :: String.t()
  defp uuid(
         <<a::binary-size(4), b::binary-size(2), c::binary-size(2), d::binary-size(2),
           e::binary-size(6)>>
       ) do
    [a, b, c, d, e] |> Enum.map(&Base.encode16(&1, case: :lower)) |> Enum.join("-")
  end

  property "seal then open round-trips for any key, nonce and canonical route" do
    device_private = draw("device_private", binary(32, 32))
    ephemeral = draw("ephemeral_private", binary(32, 32))
    nonce = draw("nonce", binary(12, 12))
    route = draw("route", route_gen())
    host = "control.example.test"
    payload = %{kind: :needs_input, route: route}
    public = PushPoke.public_key(device_private)

    case PushPoke.seal(payload, public, host, ephemeral_private: ephemeral, nonce: nonce) do
      {:ok, poke} -> assert {:ok, ^payload} = PushPoke.open(poke, device_private, host)
      # Low-order results are refused rather than producing a zero key.
      {:error, :invalid_key} -> :ok
    end
  end

  property "flipping any bit of a sealed poke is refused" do
    device_private = draw("device_private", binary(32, 32))
    route = draw("route", route_gen())
    host = "control.example.test"
    public = PushPoke.public_key(device_private)
    {:ok, poke} = PushPoke.seal(%{kind: :needs_input, route: route}, public, host)
    bytes = Base.url_decode64!(poke, padding: false)
    index = draw("index", integer(0, byte_size(bytes) - 1))
    bit = draw("bit", integer(0, 7))
    <<head::binary-size(^index), byte, tail::binary>> = bytes
    tampered = head <> <<Bitwise.bxor(byte, Bitwise.bsl(1, bit))>> <> tail
    encoded = Base.url_encode64(tampered, padding: false)

    assert {:error, reason} = PushPoke.open(encoded, device_private, host)
    assert reason in [:version, :authentication]
  end

  property "opening arbitrary bytes never raises and never yields a payload" do
    bytes = draw("bytes", binary(0, 700))
    device_private = draw("device_private", binary(32, 32))
    poke = Base.url_encode64(bytes, padding: false)
    assert {:error, _} = PushPoke.open(poke, device_private, "control.example.test")
  end
end
