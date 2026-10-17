defmodule Marshall.Accounts.RegistrationTest do
  use Marshall.DataCase, async: false
  alias Marshall.Accounts.{AuthEmail, User}
  alias Marshall.Compute.Ledger

  @context %{private: %{ash_authentication?: true}}

  test "new users register only after consuming their delivered link" do
    email = "new-#{binary_part(Ash.UUID.generate(), 0, 16)}@EXAMPLE.TEST"
    assert users_for(email) == []
    assert :ok = request(email)
    assert users_for(email) == []
    assert [_] = Ledger.read!(AuthEmail)
    assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :mail)
    assert_receive {:email, message}
    [_, token] = Regex.run(~r{/magic_link/([^\s]+)}, message.text_body)
    assert {:ok, user} = sign_in(token)
    assert String.downcase(to_string(user.email)) == String.downcase(email)
    assert {:error, _} = sign_in(token)

    assert {:ok, same} = sign_in(token(String.downcase(email)))
    assert same.id == user.id
    assert [%{id: id}] = users_for(email)
    assert id == same.id
  end

  test "all valid domains admit requests without creating users before verification" do
    for domain <- ["example.test", "elsewhere.test", "sub.example.test"] do
      email = "person@#{domain}"
      assert :ok = request(email)
      assert users_for(email) == []
      assert {:ok, user} = sign_in(token(email))
      assert to_string(user.email) == email
    end

    assert length(Ledger.read!(AuthEmail)) == 3
  end

  test "malformed mailboxes cannot request registration mail" do
    for email <- [
          "person@bad_domain.test",
          "person@-invalid.test",
          "person@example.test\r\nBcc: other@example.test"
        ] do
      before = users_for(email)
      assert {:error, _} = request(email)
      assert users_for(email) == before
    end

    assert [] == Ledger.read!(AuthEmail)
    assert %{rows: [[0]]} = Ecto.Adapters.SQL.query!(Repo, "SELECT count(*) FROM tokens")
  end

  test "previously issued tokens cannot bypass mailbox validation" do
    for email <- ["person@bad_domain.test", "person@-invalid.test"] do
      before = users_for(email)
      assert {:error, _} = sign_in(token(email))
      assert users_for(email) == before
    end
  end

  test "Linux account naming does not restrict valid verified mailboxes" do
    for email <- ["root@example.test", "person+tag@example.test", "9person@example.test"] do
      assert :ok = request(email)
      assert users_for(email) == []
      assert {:ok, user} = sign_in(token(email))
      assert to_string(user.email) == email

      assert {:ok, guest} =
               Ledger.transaction(fn -> Marshall.Accounts.GuestAccounts.ensure!(user.id) end)

      assert guest.username == "u#{guest.uid}"
    end
  end

  @spec users_for(String.t()) :: [User.t()]
  defp users_for(email) do
    Ash.read!(User, authorize?: false)
    |> Enum.filter(&(String.downcase(to_string(&1.email)) == String.downcase(email)))
  end

  @spec request(String.t()) :: :ok | {:error, term()}
  defp request(email) do
    User
    |> Ash.ActionInput.for_action(:request_magic_link, %{email: email}, context: @context)
    |> Ash.run_action()
  end

  @spec sign_in(String.t()) :: {:ok, User.t()} | {:error, term()}
  defp sign_in(token) do
    User
    |> Ash.Changeset.for_create(:sign_in_with_magic_link, %{token: token}, context: @context)
    |> Ash.create()
  end

  @spec token(String.t()) :: String.t()
  defp token(email) do
    strategy = AshAuthentication.Info.strategy!(User, :magic_link)

    {:ok, token} =
      AshAuthentication.Strategy.MagicLink.request_token_for_identity(strategy, email)

    token
  end
end
