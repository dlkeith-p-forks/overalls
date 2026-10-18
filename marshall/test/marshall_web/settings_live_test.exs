defmodule MarshallWeb.AccountGitSettingsLiveTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  import Marshall.ComputeFixtures

  @spec signed_in(Plug.Conn.t(), Marshall.Accounts.User.t()) :: Plug.Conn.t()
  defp signed_in(conn, user) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(user)
    user = Ash.Resource.put_metadata(user, :token, token)
    conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end

  test "settings require sign in", %{conn: conn} do
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(conn, ~p"/settings")
  end

  test "the form persists only the signed-in account preferences across reload", %{conn: conn} do
    owner = user()
    other = user()
    conn = signed_in(conn, owner)
    {:ok, view, _} = live(conn, ~p"/settings")
    assert has_element?(view, "#nav-account[aria-current=page]")
    assert has_element?(view, "#settings_git_username[value='Overalls']")

    view
    |> form("#git-settings-form",
      settings: %{
        git_username: "Account Author",
        git_email: "author@example.org",
        commit_trailers_enabled: false
      }
    )
    |> render_submit()

    assert has_element?(view, "#settings_git_username[value='Account Author']")
    assert has_element?(view, "#settings_git_email[value='author@example.org']")
    refute has_element?(view, "#settings_commit_trailers_enabled[checked]")

    GenServer.stop(view.pid)
    {:ok, reloaded, _} = live(conn, ~p"/settings")
    assert has_element?(reloaded, "#settings_git_username[value='Account Author']")
    refute has_element?(reloaded, "#settings_commit_trailers_enabled[checked]")
    assert Marshall.Accounts.Security.current(other.id).git_username == "Overalls"
  end

  test "Git settings ignore submitted account IDs and refuse invalid input", %{conn: conn} do
    owner = user()
    other = user()
    {:ok, view, _} = live(signed_in(conn, owner), ~p"/settings")

    render_submit(view, "save_git_settings", %{
      "settings" => %{"id" => other.id, "git_username" => "Current Account"}
    })

    assert Marshall.Accounts.Security.current(owner.id).git_username == "Current Account"
    assert Marshall.Accounts.Security.current(other.id).git_username == "Overalls"

    render_submit(view, "save_git_settings", %{"settings" => %{"git_email" => "invalid"}})
    assert has_element?(view, "#flash-error", "Enter a valid Git name and email address.")
    assert Marshall.Accounts.Security.current(owner.id).git_email == owner.git_email
  end

  test "a revoked login cannot change settings on an existing page", %{conn: conn} do
    owner = user()
    conn = signed_in(conn, owner)
    {:ok, view, _} = live(conn, ~p"/settings")

    :ok =
      AshAuthentication.TokenResource.Actions.revoke(
        Marshall.Accounts.Token,
        get_session(conn, "user_token")
      )

    view |> form("#git-settings-form", settings: %{git_username: "Revoked"}) |> render_submit()
    assert_redirect(view, ~p"/sign-in")
    assert Marshall.Accounts.Security.current(owner.id).git_username == "Overalls"
  end
end
