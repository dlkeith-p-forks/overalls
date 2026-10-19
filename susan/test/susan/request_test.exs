defmodule Susan.Poke.RequestTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias Susan.{Keyring, PushKey}
  alias Susan.Poke.Request

  @fixture Path.expand("../../../protocol/test/fixtures/susan_poke_request.json", __DIR__)

  # The relay section pairs the shared OverallsProtocol.SusanPoke vectors with
  # a push key sealed under a test keyring.
  defp fixture, do: (@fixture |> File.read!() |> JSON.decode!())["relay"]

  test "the shared protocol fixture parses, verifies and opens with its test keyring" do
    doc = fixture()
    headers = doc["headers"]

    assert {:ok, request} =
             Request.parse(
               doc["body"],
               headers["overalls-install-key"],
               headers["overalls-install-signature"]
             )

    assert Request.signed?(request)
    assert Request.fingerprint(request.install_key) == doc["install_fingerprint"]
    assert request.kind == :needs_input and request.issued_at == doc["now"]
    {:ok, keyring} = Keyring.parse(JSON.encode!(doc["test_keyring"]))
    assert {:ok, key} = PushKey.open(keyring, request.push_key, doc["now"])
    assert key.key_id == doc["expected"]["key_id"] and key.deployment == request.deployment
    seed = Base.decode16!(doc["install"]["seed_hex"], case: :lower)
    assert {public, _} = :crypto.generate_key(:eddsa, :ed25519, seed)
    assert Base.url_encode64(public, padding: false) == headers["overalls-install-key"]
  end

  test "non-canonical bodies and signatures over the bare body are refused" do
    doc = fixture()
    %{"overalls-install-key" => key, "overalls-install-signature" => sig} = doc["headers"]
    spaced = String.replace(doc["body"], ",", ", ")
    assert :error = Request.parse(spaced, key, sig)

    seed = Base.decode16!(doc["install"]["seed_hex"], case: :lower)
    bare = :crypto.sign(:eddsa, :none, doc["body"], [seed, :ed25519])
    {:ok, request} = Request.parse(doc["body"], key, Base.url_encode64(bare, padding: false))
    refute Request.signed?(request)
  end

  test "the schema is closed" do
    doc = fixture()
    %{"overalls-install-key" => key, "overalls-install-signature" => sig} = doc["headers"]
    body = JSON.decode!(doc["body"])
    good = fn value -> Request.parse(JSON.encode!(value), key, sig) end
    assert {:ok, _} = good.(body)
    assert :error = good.(Map.put(body, "route", "overalls://x/threads"))
    assert :error = good.(Map.delete(body, "nonce"))
    assert :error = good.(%{body | "kind" => "message"})
    assert :error = good.(%{body | "delivery_id" => String.upcase(body["delivery_id"])})
    assert :error = good.(%{body | "issued_at" => "1792540800"})
    assert :error = good.(%{body | "nonce" => Base.url_encode64(<<1, 2, 3>>, padding: false)})
    assert :error = good.(%{body | "collapse_id" => String.duplicate("a", 65)})
    assert :error = good.(%{body | "deployment" => "Control.Example.Test"})
    assert :error = good.(%{body | "ciphertext" => "not base64!"})
    assert :error = Request.parse(String.duplicate(" ", 1025), key, sig)
    assert :error = Request.parse(doc["body"], nil, sig)
    assert :error = Request.parse(doc["body"], key <> "A", sig)
    assert :error = Request.parse(doc["body"], key, binary_part(sig, 0, 80))
  end

  @tag :hegel
  test "arbitrary bytes never raise and never parse" do
    Hegel.check(
      fn ->
        body = draw("body", binary(0, 1100))
        key = draw("key", one_of([constant(nil), string(:alphanumeric, max_length: 50)]))
        assert Request.parse(body, key, key) == :error
      end,
      test_cases: 300
    )
  end
end
