defmodule Marshall.Accounts.FixtureOperatorLoginTest do
  @moduledoc "Real magic-link login to passkey enrollment path used by the fixture operator."
  use Marshall.DataCase, async: false

  alias Marshall.Accounts.{Security, User}

  test "a new magic-link actor can enroll a passkey on its stored login" do
    email = "fixture-#{binary_part(Ash.UUID.generate(), 0, 16)}@example.test"
    strategy = AshAuthentication.Info.strategy!(User, :magic_link)

    {:ok, magic_token} =
      AshAuthentication.Strategy.MagicLink.request_token_for_identity(strategy, email)

    {:ok, user} =
      User
      |> Ash.Changeset.new()
      |> Ash.Changeset.set_context(%{private: %{ash_authentication?: true}})
      |> Ash.Changeset.for_create(:sign_in_with_magic_link, %{
        token: magic_token,
        remember_me: true
      })
      |> Ash.create()

    token = Ash.Resource.get_metadata(user, :token)
    {:ok, %{"jti" => jti}, User} = AshAuthentication.Jwt.verify(token, User)
    {:ok, _} = Security.primary(user, jti)
    actor = Security.bind(user, jti)

    challenge = expect_ok(security(actor, :begin_register), "begin_register")
    key = Marshall.PasskeyFixture.authenticator()
    payload = Marshall.PasskeyFixture.registration(challenge, key)

    assert %{registered: true} =
             expect_ok(security(actor, :finish_register, payload), "finish_register")
  end

  @spec security(User.t(), atom(), map()) :: {:ok, map()} | {:error, term()}
  defp security(actor, operation, payload \\ %{}) do
    User
    |> Ash.ActionInput.for_action(:security, %{operation: operation, payload: payload},
      actor: actor
    )
    |> Ash.run_action()
  end

  @spec expect_ok({:ok, map()} | {:error, term()}, String.t()) :: map()
  defp expect_ok({:ok, value}, _phase), do: value
  defp expect_ok({:error, _}, phase), do: flunk("#{phase} failed")
end
