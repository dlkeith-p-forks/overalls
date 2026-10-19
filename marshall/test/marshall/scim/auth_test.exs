defmodule Marshall.Scim.AuthTest do
  use ExUnit.Case, async: true

  test "token digests are deterministic and do not equal the bearer token" do
    token = "scim_test_token"
    digest = Marshall.Scim.Auth.digest(token)

    assert is_binary(digest)
    assert digest != token
    assert digest == Marshall.Scim.Auth.digest(token)
    refute digest == Marshall.Scim.Auth.digest(token <> "-rotated")
  end
end
