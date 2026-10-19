defmodule MarshallWeb.SignOutLiveTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest

  test "anonymous confirmation uses English fallback and retains the library DELETE form", %{
    conn: conn
  } do
    {:ok, view, _} = live(put_req_header(conn, "accept-language", "zz-ZZ"), ~p"/sign-out")
    assert has_element?(view, ".auth-panel h2", "Sign out")
    assert has_element?(view, ".auth-panel p", "Are you sure you want to sign out?")

    assert has_element?(
             view,
             "form[action='/sign-out'][method=post] input[name='_method'][value=delete]"
           )

    assert has_element?(view, "form[action='/sign-out'] input[name='_csrf_token']")
  end

  test "saved language overrides the browser on connected confirmation and reload", %{conn: conn} do
    for locale <- ~w(ar ja) do
      owner =
        Ash.Seed.seed!(Marshall.Accounts.User, %{
          email: "sign-out-#{Ash.UUID.generate()}@example.test",
          locale: locale
        })

      signed = conn |> signed_in(owner) |> put_req_header("accept-language", "en")
      token = get_session(signed, "user_token")
      assert {:ok, jti, _} = Marshall.Accounts.Login.verify(token, owner)

      expected =
        Gettext.with_locale(MarshallWeb.Gettext, locale, fn ->
          Gettext.dgettext(MarshallWeb.Gettext, "auth", "Are you sure you want to sign out?")
        end)

      refute expected == "Are you sure you want to sign out?"

      for _ <- 1..2 do
        {:ok, view, _} = live(signed, ~p"/sign-out")
        assert has_element?(view, ".auth-panel p", expected)
        assert {:ok, _} = Marshall.Accounts.Login.token_check(jti, owner.id)
        GenServer.stop(view.pid)
      end

      # Leaving confirmation without submitting it preserves the current login.
      assert get(signed, ~p"/overview").status == 200
      assert {:ok, _} = Marshall.Accounts.Login.token_check(jti, owner.id)
    end
  end

  test "sign-out refuses a missing CSRF token without revoking the login", %{conn: conn} do
    owner = Marshall.ComputeFixtures.user()
    signed = signed_in(conn, owner)

    assert {:ok, jti, _} =
             Marshall.Accounts.Login.verify(get_session(signed, "user_token"), owner)

    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      signed
      |> put_private(:plug_skip_csrf_protection, false)
      |> delete(~p"/sign-out")
    end

    assert {:ok, _} = Marshall.Accounts.Login.token_check(jti, owner.id)
  end

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

  @spec signed_in(Plug.Conn.t(), Marshall.Accounts.User.t()) :: Plug.Conn.t()
  defp signed_in(conn, owner) do
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(owner)
    owner = Ash.Resource.put_metadata(owner, :token, token)
    conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(owner)
  end
end
