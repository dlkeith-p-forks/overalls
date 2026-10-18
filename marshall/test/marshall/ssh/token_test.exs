defmodule Marshall.SSH.TokenTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Marshall.SSH.Token

  property "tokens are purpose bound and their canonical digest is stable" do
    purpose = draw("purpose", member_of([:gateway, :session, :approval]))
    {token, hash} = Token.issue(purpose)
    assert {:ok, ^hash} = Token.digest(token, purpose)
    assert :error = Token.digest(token <> "=", purpose)

    for other <- [:gateway, :session, :approval] -- [purpose],
        do: assert(:error == Token.digest(token, other))
  end

  property "arbitrary credentials fail without raising" do
    value = draw("value", term())
    assert Token.digest(value, :session) == :error
  end
end
