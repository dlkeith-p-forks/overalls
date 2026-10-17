defmodule MarshallWeb.RememberMeLoginTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Marshall.Accounts.{Login, Security, User, Verification}
  alias Marshall.Compute.Ledger
  alias Marshall.PasskeyFixture, as: Fixture

  setup do
    [bootstrap] = Ledger.read!(Marshall.Accounts.AdminBootstrap, id: "installation")
    Ledger.update!(bootstrap, :complete, %{})
    :ok
  end

  # @cc [owner:ghuntley,label:verification] remember-login-mfa-boundary
  # A real remembered sign-in MUST allow ordinary access without inheriting
  # passkey elevation or a fresh email receipt. Sign-out MUST revoke both browser
  # and remember credentials; replaying copied cookies MUST NOT restore authority.
  test "remembered enrolled login allows reads, requires its own admin elevation and revokes copied cookies" do
    actor = Fixture.elevate(Fixture.user(true))
    {cookie_name, cookie} = remember_cookie(actor)
    response = build_conn() |> put_req_cookie(cookie_name, cookie) |> get("/settings/security")
    assert response.status == 200
    token = get_session(response, "user_token")
    assert is_binary(token)
    assert {:ok, jti, _} = Login.verify(token, actor)
    refute jti == Security.jti(actor)
    assert Ledger.read!(Verification, id: jti) == []
    refute Security.passkey_verified?(jti, actor.id)

    conn = recycle(response)
    {:ok, ordinary, _} = live(conn, "/overview")
    assert has_element?(ordinary, "#main-content")
    assert get(conn, "/admin/usage/export").status == 200
    target = Fixture.user()
    {:ok, admin, _} = live(conn, "/admin/users")
    render_click(admin, "set-role", %{"id" => target.id, "enabled" => "true"})
    assert_push_event(admin, "admin-step-up-open", %{nonce: nonce})
    assert OverallsProtocol.uuid?(nonce)
    refute Security.current(target.id).administrator
    resumed = Security.bind(actor, jti)

    assert {:ok, %{verified: true}} =
             Fixture.verify(resumed, actor.__metadata__.test_authenticator)

    {:ok, view, _} = live(conn, "/overview")
    GenServer.stop(view.pid)

    signed_out = delete(conn, "/sign-out")
    assert signed_out.resp_cookies[cookie_name].max_age == 0
    assert :error = Login.verify(token, actor)
    copied = build_conn() |> put_req_cookie(cookie_name, cookie) |> get("/overview")
    assert redirected_to(copied) == "/sign-in"
    assert copied.resp_cookies[cookie_name].max_age == 0
  end

  test "remembered first enrollment cannot replace fresh primary email authentication" do
    actor = Fixture.user()
    {cookie_name, cookie} = remember_cookie(actor)
    response = build_conn() |> put_req_cookie(cookie_name, cookie) |> get("/settings/security")
    assert response.status == 200
    {:ok, jti, _} = Login.verify(get_session(response, "user_token"), actor)
    assert Ledger.read!(Verification, id: jti) == []
    assert {:error, _} = Fixture.action(Security.bind(actor, jti), :begin_register)
  end

  test "Sign out everywhere prevents a no-MFA account resuming copied remember authority" do
    admin = Fixture.elevate(Fixture.user(true))
    account = Fixture.user()
    {name, cookie} = remember_cookie(account)
    response = build_conn() |> put_req_cookie(name, cookie) |> get("/overview")
    assert response.status == 200
    token = get_session(response, "user_token")

    input =
      Ash.ActionInput.for_action(User, :revoke_sessions_for_admin, %{user_id: account.id},
        actor: admin
      )

    assert {:ok, %{revoked: count}} = Ash.run_action(input)
    assert count >= 2
    assert :error = Login.verify(token, account)
    copied = build_conn() |> put_req_cookie(name, cookie) |> get("/overview")
    assert redirected_to(copied) == "/sign-in"
  end

  test "sign-out removes a remembered credential without a live login and across subjects" do
    for current_login <- [nil, Fixture.login(Fixture.user())] do
      account = Fixture.user()
      {name, cookie} = remember_cookie(account)
      conn = build_conn() |> init_test_session(%{}) |> put_req_cookie(name, cookie)

      conn =
        case current_login do
          nil ->
            conn |> put_session("user_token", "expired-or-invalid")

          {actor, token} ->
            AshAuthentication.Plug.Helpers.store_in_session(
              conn,
              Ash.Resource.put_metadata(actor, :token, token)
            )
        end

      response = delete(conn, "/sign-out")
      assert response.resp_cookies[name].max_age == 0
      copied = build_conn() |> put_req_cookie(name, cookie) |> get("/overview")
      assert redirected_to(copied) == "/sign-in"
    end
  end

  test "MFA reset and retirement reject persistent browser credential exchange" do
    admin = Fixture.elevate(Fixture.user(true))

    for operation <- [:reset_mfa, :delete_user] do
      account = Fixture.user()
      {name, cookie} = remember_cookie(account)

      args =
        if operation == :delete_user,
          do: %{user_id: account.id, confirmation: to_string(account.email)},
          else: %{user_id: account.id}

      assert {:ok, _} =
               User
               |> Ash.ActionInput.for_action(operation, args, actor: admin)
               |> Ash.run_action()

      response = build_conn() |> put_req_cookie(name, cookie) |> get("/overview")
      assert redirected_to(response) == "/sign-in"
    end
  end

  @spec remember_cookie(User.t()) :: {String.t(), String.t()}
  defp remember_cookie(user) do
    strategy = AshAuthentication.Info.strategy!(User, :magic_link)
    {:ok, token} = AshAuthentication.Strategy.MagicLink.request_token_for(strategy, user)

    response =
      post(build_conn(), "/auth/user/magic_link", %{
        "user" => %{"token" => token, "remember_me" => "true"}
      })

    assert response.status == 302
    remember = AshAuthentication.Info.strategy!(User, :remember_me)
    name = to_string(remember.cookie_name)
    assert %{value: cookie, secure: true, http_only: true} = response.resp_cookies[name]
    {name, cookie}
  end
end
