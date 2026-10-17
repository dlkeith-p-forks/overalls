defmodule MarshallWeb.AuthControllerTest do
  use MarshallWeb.ConnCase, async: false
  import ExUnit.CaptureLog
  import Marshall.TerminalFixtures, only: [user_token: 1]
  alias MarshallWeb.AuthController

  defp user,
    do: Ash.Seed.seed!(Marshall.Accounts.User, %{email: "#{Ash.UUID.generate()}@example.test"})

  defp session_conn,
    do: build_conn() |> init_test_session(%{}) |> fetch_session() |> fetch_flash()

  test "successful sign-in emits a correlated structured event" do
    account = user()
    token = user_token(account)
    account = Ash.Resource.put_metadata(account, :token, token)
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    logs =
      capture_log([metadata: [:event, :user_id]], fn ->
        conn = AuthController.success(session_conn(), {:magic_link, :sign_in}, account, nil)
        assert redirected_to(conn) == ~p"/overview"
      end)

    assert logs =~ "event=auth.signed_in"
    assert logs =~ "user_id=#{account.id}"
  end

  test "failed sign-in emits a closed-reason structured event" do
    logs =
      capture_log([metadata: [:event, :reason]], fn ->
        response =
          AuthController.failure(
            session_conn(),
            {:password, :sign_in},
            %AshAuthentication.Errors.AuthenticationFailed{}
          )

        assert redirected_to(response) == ~p"/sign-in"
      end)

    assert logs =~ "event=auth.sign_in_failed"
    assert logs =~ "reason=invalid_credentials"
  end

  test "sign-out emits a correlated structured event" do
    account = user()
    level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: level) end)

    logs =
      capture_log([metadata: [:event, :user_id]], fn ->
        conn =
          session_conn()
          |> assign(:current_user, account)
          |> AuthController.sign_out(%{})

        assert redirected_to(conn) == ~p"/"
      end)

    assert logs =~ "event=auth.signed_out"
    assert logs =~ "user_id=#{account.id}"
  end

  # @cc [owner:ghuntley,label:verification] success-callback-revoked-login
  # A login revoked between sign-in issuance and the authentication callback
  # MUST refuse cleanly: no session, no 5xx and no token details.
  test "a login revoked between issuance and the success callback refuses the session" do
    account = user()
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(account)
    assert {:ok, _jti, _} = Marshall.Accounts.Login.verify(token, account)
    :ok = Marshall.Accounts.AccountLifecycle.revoke_tokens!(account.id)
    assert :error = Marshall.Accounts.Login.verify(token, account)

    account = Ash.Resource.put_metadata(account, :token, token)

    logs =
      capture_log([metadata: [:event, :reason]], fn ->
        conn =
          session_conn()
          |> put_session("return_to", "/overview")
          |> AuthController.success({:magic_link, :sign_in}, account, token)

        assert redirected_to(conn) == "/sign-in"
        assert conn.status == 302
        refute get_session(conn, "user_token")
        refute get_session(conn, "return_to")

        flash = Phoenix.Flash.get(conn.assigns.flash, :error)
        assert flash =~ "Request a new sign-in link"
        refute flash =~ token
      end)

    assert logs =~ "event=auth.sign_in_failed"
    assert logs =~ "reason=session_revoked"
    refute logs =~ token
  end

  test "a live login stores the session through the success callback" do
    account = user()
    token = user_token(account)
    account = Ash.Resource.put_metadata(account, :token, token)

    conn = AuthController.success(session_conn(), {:magic_link, :sign_in}, account, nil)

    assert redirected_to(conn) == "/overview"
    assert get_session(conn, "user_token")

    assert {:ok, jti, _} = Marshall.Accounts.Login.verify(token, account)
    refute Marshall.Accounts.Security.passkey_verified?(jti, account.id)
  end

  test "sign-in in another tab resumes valid launch ahead of onboarding return" do
    account = user()
    token = user_token(account)
    account = Ash.Resource.put_metadata(account, :token, token)

    {:ok, pending} =
      MarshallWeb.PendingLaunch.new(
        "https://github.com/antithesishq/weaver",
        String.duplicate("a", 32)
      )

    conn =
      session_conn()
      |> put_session(MarshallWeb.PendingLaunch.key(), pending)
      |> put_session(:return_to, "/settings/ssh-keys")
      |> AuthController.success({:magic_link, :sign_in}, account, nil)

    assert redirected_to(conn) == "/launch"
    assert get_session(conn, MarshallWeb.PendingLaunch.key()) == pending
    refute get_session(conn, :return_to)
  end

  test "enrolled sign-in continues the staged launch without requiring elevation" do
    {actor, _} = Marshall.PasskeyFixture.login(Marshall.PasskeyFixture.user())
    Marshall.PasskeyFixture.register(actor)
    token = user_token(actor)
    account = Ash.Resource.put_metadata(actor, :token, token)

    {:ok, pending} =
      MarshallWeb.PendingLaunch.new(
        "https://github.com/antithesishq/weaver",
        String.duplicate("a", 32)
      )

    conn =
      session_conn()
      |> put_session(MarshallWeb.PendingLaunch.key(), pending)
      |> AuthController.success({:magic_link, :sign_in}, account, nil)

    assert redirected_to(conn) == "/launch"
    assert get_session(conn, MarshallWeb.PendingLaunch.key()) == pending
    assert {:ok, jti, _} = Marshall.Accounts.Login.verify(token, actor)
    refute Marshall.Accounts.Security.passkey_verified?(jti, actor.id)
  end

  test "expired pending launch does not override ordinary sign-in return" do
    account = user()
    token = user_token(account)
    account = Ash.Resource.put_metadata(account, :token, token)

    {:ok, pending} =
      MarshallWeb.PendingLaunch.new(
        "https://github.com/antithesishq/weaver",
        String.duplicate("a", 32),
        System.system_time(:second) - 1_800
      )

    conn =
      session_conn()
      |> put_session(MarshallWeb.PendingLaunch.key(), pending)
      |> put_session(:return_to, "/settings/ssh-keys")
      |> AuthController.success({:magic_link, :sign_in}, account, nil)

    assert redirected_to(conn) == "/settings/ssh-keys"
  end
end
