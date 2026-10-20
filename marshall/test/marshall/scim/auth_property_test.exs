defmodule Marshall.Scim.AuthPropertyTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  property "digesting a token is stable and rotation changes the digest", test_cases: 100 do
    token = draw(string(:alphanumeric, min_length: 1, max_length: 128))
    replacement = draw(string(:alphanumeric, min_length: 1, max_length: 128))
    assume(token != replacement)

    digest = Marshall.Scim.Auth.digest(token)
    assert digest == Marshall.Scim.Auth.digest(token)
    refute digest == Marshall.Scim.Auth.digest(replacement)
    refute digest == token
  end

  property "digest output is fixed width and never reveals bearer material", test_cases: 100 do
    token = draw(string(:printable, min_length: 16, max_length: 512))
    digest = Marshall.Scim.Auth.digest(token)

    assert is_binary(digest)
    # SHA-256 encoded as base64 is always 44 bytes (including padding).
    assert byte_size(digest) == 44
    refute String.contains?(digest, token)
  end

  property "distinct generated credentials remain distinguishable", test_cases: 100 do
    left = draw(string(:alphanumeric, min_length: 8, max_length: 128))
    right = draw(string(:alphanumeric, min_length: 8, max_length: 128))

    if left != right do
      refute Plug.Crypto.secure_compare(
               Marshall.Scim.Auth.digest(left),
               Marshall.Scim.Auth.digest(right)
             )
    end
  end
end
