defmodule Marshall.Scim.AuthPropertyTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  property "digesting a token is stable and rotation changes the digest", test_cases: 100 do
    check all(
            token <- string(:alphanumeric, min_length: 1, max_length: 128),
            replacement <- string(:alphanumeric, min_length: 1, max_length: 128),
            token != replacement
          ) do
      digest = Marshall.Scim.Auth.digest(token)
      assert digest == Marshall.Scim.Auth.digest(token)
      refute digest == Marshall.Scim.Auth.digest(replacement)
      refute digest == token
    end
  end
end
