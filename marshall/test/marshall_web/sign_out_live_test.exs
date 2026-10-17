defmodule MarshallWeb.SignOutLiveTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  # @cc [owner:ghuntley,label:verification;security] sign-out-ends-open-pages
  # Signing out MUST end every open live page of that login: the next event or
  # message an open page handles redirects it to sign-in. A definite refusal is
  # never mistaken for an inconclusive lookup.
  test "signing out in one tab sends an open live page to sign-in", %{conn: conn} do
    owner = Marshall.ComputeFixtures.user()
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(owner)
    owner = Ash.Resource.put_metadata(owner, :token, token)

    conn =
      conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(owner)

    {:ok, view, _html} = live(conn, ~p"/machines")

    {:ok, jti, _} = Marshall.Accounts.Login.verify(token, owner)
    assert {:ok, _} = Marshall.Accounts.Login.token_check(jti, owner.id)

    conn
    |> Phoenix.Controller.fetch_flash([])
    |> Plug.Conn.assign(:current_user, owner)
    |> MarshallWeb.AuthController.sign_out(%{})

    assert Marshall.Accounts.Login.token_check(jti, owner.id) == :refused
    send(view.pid, :refresh)
    assert_redirect(view, ~p"/sign-in")
  end
end
