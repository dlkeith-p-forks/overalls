defmodule MarshallWeb.AdminAccessLiveTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Marshall.Accounts.User

  test "access authority is available to signed-in users and redacts empty inventory", %{
    conn: conn
  } do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/admin/access")

    ordinary = Ash.Seed.seed!(User, %{email: "access-#{Ash.UUID.generate()}@example.test"})

    assert {:ok, _, _} = live(signed_in(conn, ordinary), ~p"/admin/access")

    admin =
      Ash.Seed.seed!(User, %{
        email: "admin-access-#{Ash.UUID.generate()}@example.test",
        administrator: true
      })

    {:ok, view, _} = live(signed_in(conn, admin), ~p"/admin/access")
    assert has_element?(view, "h1", "Access authority")
    assert has_element?(view, "#main-content")
    refute render(view) =~ "token_hash"
    refute render(view) =~ "private key"
  end

  defp signed_in(conn, user) do
    user = if user.administrator, do: Marshall.PasskeyFixture.verified_session(user), else: user

    {:ok, token, _} =
      if user.__metadata__[:token],
        do: {:ok, user.__metadata__.token, %{}},
        else: AshAuthentication.Jwt.token_for_user(user)

    user = Ash.Resource.put_metadata(user, :token, token)
    conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
