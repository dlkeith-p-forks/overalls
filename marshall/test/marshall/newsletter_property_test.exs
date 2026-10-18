defmodule Marshall.NewsletterPropertyTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  property "only bounded valid mailboxes can reach the subscription boundary", test_cases: 100 do
    value = draw("email", one_of([string(:printable, max_length: 300), binary(max_length: 300)]))

    if Marshall.Accounts.EmailAddress.valid?(value) do
      assert Marshall.Accounts.EmailAddress.valid?(value)
    else
      assert Marshall.Newsletter.subscribe(value) == {:error, :invalid_email}
    end
  end
end
