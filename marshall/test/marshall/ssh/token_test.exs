defmodule Marshall.SSH.TokenTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Marshall.SSH.Token

  property "tokens are purpose bound and their canonical digest is stable" do
    check all(purpose <- member_of([:gateway, :session, :approval])) do
      {token, hash} = Token.issue(purpose)
      assert {:ok, ^hash} = Token.digest(token, purpose)
      assert :error = Token.digest(token <> "=", purpose)

      for other <- [:gateway, :session, :approval] -- [purpose],
          do: assert(:error == Token.digest(token, other))
    end
  end

  property "arbitrary credentials fail without raising" do
    check all(value <- term()) do
      assert Token.digest(value, :session) == :error
    end
  end
end
