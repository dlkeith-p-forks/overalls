defmodule Marshall.Accounts.GuestUsernameTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Marshall.Accounts.GuestUsername

  test "the finite UID range determines the Linux login" do
    assert GuestUsername.from_uid(200_000) == {:ok, "u200000"}
    assert GuestUsername.from_uid(999_999) == {:ok, "u999999"}

    for value <- [199_999, 1_000_000, -1, nil, "200000", 200_000.0, "root@example.test"] do
      assert GuestUsername.from_uid(value) == :error
    end
  end

  property "every allocated UID has one distinct safe home component" do
    check all(left <- integer(200_000..999_999), right <- integer(200_000..999_999)) do
      assert {:ok, name} = GuestUsername.from_uid(left)
      assert name == "u" <> Integer.to_string(left)
      assert Regex.match?(~r/\Au[2-9][0-9]{5}\z/, name)
      assert Path.basename("/home/" <> name) == name
      assert {:ok, other} = GuestUsername.from_uid(right)
      assert name == other == (left == right)
    end
  end
end
