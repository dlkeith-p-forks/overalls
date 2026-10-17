defmodule MarshallWeb.PageControllerTest do
  use MarshallWeb.ConnCase
  import Phoenix.LiveViewTest

  alias Marshall.Accounts.User

  test "GET / sends anonymous visitors to public fragment capture", %{conn: conn} do
    conn = get(conn, ~p"/")
    assert redirected_to(conn) == ~p"/launch/entry"

    assert html_response(get(recycle(conn), ~p"/launch/entry"), 200) =~
             "repository-launch-capture"
  end

  test "GET / sends authenticated users through repository launch", %{conn: conn} do
    user = Ash.Seed.seed!(User, %{email: "#{Ash.UUID.generate()}@example.test"})
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)

    conn =
      conn
      |> init_test_session(%{})
      |> AshAuthentication.Plug.Helpers.store_in_session(user)

    assert redirected_to(get(conn, ~p"/")) == ~p"/launch/entry"

    # Without a repository fragment the launch hook reports idle and continues home.
    assert {:error, {:live_redirect, %{to: "/overview"}}} = live(conn, ~p"/launch")
  end

  test "anonymous launch visits go to sign-in without launching", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/launch")
  end
end
