defmodule Marshall.Scim.OidcIdTokenPropertyTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias Marshall.Scim.Oidc.{IdToken, VerifiedClaims}

  @issuer "https://idp.example.test"
  @client_id "overalls-client"
  @nonce "session-nonce-value"
  @now 1_800_000_000
  @alphabet ~c"ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_."

  test "untampered RS256 and ES256 tokens verify" do
    %{jwks: jwks, tokens: tokens} = fixtures()

    for {_alg, token} <- tokens do
      assert {:ok, %VerifiedClaims{subject: "subject-1", issuer: @issuer}} =
               IdToken.verify(token, jwks, expected())
    end
  end

  property "replacing any character of a signed ID token is always rejected",
    test_cases: 300 do
    %{jwks: jwks, tokens: tokens} = fixtures()
    token = Map.fetch!(tokens, draw(member_of(["RS256", "ES256"])))
    position = draw(integer(0, byte_size(token) - 1))
    replacement = draw(member_of(@alphabet))
    original = :binary.at(token, position)
    assume(replacement != original)

    tampered =
      binary_part(token, 0, position) <>
        <<replacement>> <> binary_part(token, position + 1, byte_size(token) - position - 1)

    assert {:error, _} = IdToken.verify(tampered, jwks, expected())
  end

  property "changing any decoded payload byte is always rejected", test_cases: 200 do
    %{jwks: jwks, tokens: tokens} = fixtures()
    token = Map.fetch!(tokens, draw(member_of(["RS256", "ES256"])))
    [header, payload, signature] = String.split(token, ".")
    bytes = Base.url_decode64!(payload, padding: false)
    position = draw(integer(0, byte_size(bytes) - 1))
    flip = draw(integer(1, 255))
    <<prefix::binary-size(^position), byte, rest::binary>> = bytes
    changed = prefix <> <<Bitwise.bxor(byte, flip)>> <> rest
    forged = Enum.join([header, Base.url_encode64(changed, padding: false), signature], ".")

    assert {:error, _} = IdToken.verify(forged, jwks, expected())
  end

  property "truncated or extended tokens are always rejected", test_cases: 200 do
    %{jwks: jwks, tokens: tokens} = fixtures()
    token = Map.fetch!(tokens, draw(member_of(["RS256", "ES256"])))
    cut = draw(integer(0, byte_size(token) - 1))
    suffix = draw(string(:alphanumeric, min_length: 1, max_length: 8))

    assert {:error, _} = IdToken.verify(binary_part(token, 0, cut), jwks, expected())
    assert {:error, _} = IdToken.verify(token <> suffix, jwks, expected())
  end

  property "headers re-signed with a disallowed algorithm are always rejected",
    test_cases: 50 do
    %{jwks: jwks} = fixtures()
    alg = draw(member_of(["none", "HS256", "HS512", "RS512", "PS256", "ES384"]))
    [_, payload, signature] = String.split(Map.fetch!(fixtures().tokens, "RS256"), ".")
    header = Base.url_encode64(Jason.encode!(%{"alg" => alg, "kid" => "rsa"}), padding: false)

    assert {:error, _} =
             IdToken.verify(Enum.join([header, payload, signature], "."), jwks, expected())
  end

  defp expected, do: %{issuer: @issuer, client_id: @client_id, nonce: @nonce, now: @now}

  # Key generation is slow; one key pair per algorithm is cached for the VM.
  defp fixtures do
    case :persistent_term.get({__MODULE__, :fixtures}, nil) do
      nil ->
        rsa = JOSE.JWK.generate_key({:rsa, 2048}) |> JOSE.JWK.merge(%{"kid" => "rsa"})
        ec = JOSE.JWK.generate_key({:ec, "P-256"}) |> JOSE.JWK.merge(%{"kid" => "ec"})

        fixtures = %{
          jwks: Enum.map([rsa, ec], &JOSE.JWK.to_public/1),
          tokens: %{"RS256" => sign(rsa, "RS256", "rsa"), "ES256" => sign(ec, "ES256", "ec")}
        }

        :persistent_term.put({__MODULE__, :fixtures}, fixtures)
        fixtures

      fixtures ->
        fixtures
    end
  end

  defp sign(key, alg, kid) do
    claims = %{
      "iss" => @issuer,
      "sub" => "subject-1",
      "aud" => @client_id,
      "exp" => @now + 300,
      "iat" => @now,
      "nonce" => @nonce
    }

    {_, token} = key |> JOSE.JWT.sign(%{"alg" => alg, "kid" => kid}, claims) |> JOSE.JWS.compact()
    token
  end
end
