defmodule OverallsProtocol.SusanPokeTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias OverallsProtocol.SusanPoke

  # Shared with the Susan relay so both sides sign and verify identical bytes.
  @vectors Path.expand("fixtures/susan_poke_request.json", __DIR__)
  @external_resource @vectors

  @spec vectors() :: map()
  defp vectors, do: @vectors |> File.read!() |> JSON.decode!()

  test "the fixed request round-trips, re-encodes to its exact bytes and verifies" do
    %{"version" => 1, "valid" => valid} = vectors()
    seed = Base.decode16!(valid["install_seed"], case: :lower)
    body = valid["body"]
    headers = valid["headers"]

    assert {:ok, request} = SusanPoke.decode(body)
    assert {:ok, ^body} = SusanPoke.encode(request)
    assert request.kind == :needs_input

    assert SusanPoke.sign(body, seed) == %{
             key: headers[SusanPoke.key_header()],
             signature: headers[SusanPoke.signature_header()]
           }

    assert :ok =
             SusanPoke.verify(
               body,
               headers[SusanPoke.key_header()],
               headers[SusanPoke.signature_header()]
             )

    assert {:ok, _} =
             OverallsProtocol.PushPoke.open(
               request.ciphertext,
               Base.decode16!(
                 hd(
                   JSON.decode!(File.read!(Path.expand("fixtures/push_pokes.json", __DIR__)))[
                     "valid"
                   ]
                 )["device_private"],
                 case: :lower
               ),
               request.deployment
             )
  end

  test "tampered bodies, other keys and malformed signatures are refused" do
    for vector <- vectors()["invalid"] do
      assert {:error, :invalid_signature} =
               SusanPoke.verify(vector["body"], vector["key"], vector["signature"]),
             vector["name"]
    end

    assert {:error, :invalid_signature} = SusanPoke.verify("{}", nil, "x")
    assert {:error, :invalid_signature} = SusanPoke.verify("{}", "!!", "!!")
  end

  test "non-canonical and unknown-member bodies are refused" do
    for body <- vectors()["non_canonical"] do
      assert {:error, _} = SusanPoke.decode(body), body
    end

    assert {:error, :request_too_large} = SusanPoke.decode(String.duplicate(" ", 1025))
    assert {:error, :invalid_request} = SusanPoke.decode(~s({"kind":"needs_input"}))
    assert {:error, :invalid_request} = SusanPoke.decode(nil)
  end

  test "encode refuses invalid members" do
    {:ok, request} = SusanPoke.decode(vectors()["valid"]["body"])

    for {key, value} <- [
          ciphertext: "short",
          collapse_id: "not/base64url/twenty2",
          delivery_id: "not-a-uuid",
          deployment: "Not A Host",
          issued_at: -1,
          kind: :plan_ready,
          nonce: "",
          push_key: "with space in it......"
        ] do
      assert {:error, :invalid_request} = SusanPoke.encode(%{request | key => value}),
             inspect(key)
    end

    assert {:error, :invalid_request} = SusanPoke.encode(Map.put(request, :route, "/threads"))

    assert {:error, :request_too_large} =
             SusanPoke.encode(%{
               request
               | push_key: String.duplicate("A", 512),
                 ciphertext: String.duplicate("A", 764)
             })
  end

  property "signatures verify only over the exact signed bytes" do
    seed = draw("seed", binary(32, 32))
    body = draw("body", binary(0, 256))
    %{key: key, signature: signature} = SusanPoke.sign(body, seed)
    assert :ok = SusanPoke.verify(body, key, signature)
    extra = draw("extra", binary(1, 8))
    assert {:error, :invalid_signature} = SusanPoke.verify(body <> extra, key, signature)
  end
end
