defmodule MarshallWeb.MagicLinkFlowTest do
  use MarshallWeb.ConnCase, async: false
  import ExUnit.CaptureLog
  alias Marshall.Accounts.{AuthEmail, Login, Security, Token, User, Verification}
  alias Marshall.Compute.Ledger

  @feedback "Check your email for a sign-in link. Your account will be created automatically when you sign in."
  @request_path "/auth/user/magic_link/request"
  @sign_in_path "/auth/user/magic_link"

  for existing? <- [false, true] do
    @existing? existing?
    test "HTTP requests preserve anonymous state and cooldown (existing user: #{existing?})" do
      email = "request-#{binary_part(Ash.UUID.generate(), 0, 12)}@example.test"
      if @existing?, do: Ash.Seed.seed!(User, %{email: email})
      users_before = Ash.read!(User, authorize?: false)

      logs =
        capture_auth_log(fn ->
          for address <- [email, String.upcase(email)] do
            response = request(address)
            assert_request_response(response)
            refute response.assigns[:current_user]
          end
        end)

      assert Ash.read!(User, authorize?: false) == users_before
      assert [%{status: :pending}] = Ledger.read!(AuthEmail)
      assert [] == Ledger.read!(Verification)

      assert %{rows: [[1]]} =
               Ecto.Adapters.SQL.query!(Marshall.Repo, """
               SELECT count(*) FROM oban_jobs
               WHERE worker = 'Marshall.Accounts.Workers.DeliverAuthEmail'
               """)

      refute logs =~ "auth.signed_in"
      refute logs =~ email
    end
  end

  test "invalid and disallowed HTTP requests have identical generic feedback" do
    addresses = ["invalid", "person@-invalid.test", "person@bad_domain.test", ""]
    users_before = Map.new(addresses, &{&1, users_for(&1)})

    for email <- addresses do
      assert_request_response(request(email))
      assert users_for(email) == Map.fetch!(users_before, email)
    end

    assert [] == Ledger.read!(AuthEmail)
    assert [] == Ash.read!(Token, authorize?: false)
  end

  test "the rendered sign-in form works through its ordinary HTTP action", %{conn: conn} do
    email = "form@example.test"
    users_before = users_for(email)
    page = get(conn, "/sign-in")

    [action] =
      page
      |> html_response(200)
      |> LazyHTML.from_document()
      |> LazyHTML.query("#user-magic-link-request-magic-link")
      |> LazyHTML.attribute("action")

    response = post(recycle(page), action, user: %{email: email})
    assert redirected_to(response) == "/sign-in"
    assert Phoenix.Flash.get(response.assigns.flash, :info) == @feedback
    refute get_session(response, :user_token)
    assert users_before == users_for(email)
    assert [_] = Ledger.read!(AuthEmail)
  end

  for state <- [:new, :existing, :mfa] do
    @state state
    test "delivered link automatically submits a remembered sign-in once (#{state})" do
      email = "login-#{binary_part(Ash.UUID.generate(), 0, 12)}@example.test"

      previous =
        if @state != :new,
          do: Ash.Seed.seed!(User, %{email: email, mfa_enabled: @state == :mfa})

      users_before = users_for(email)

      response = request(email)
      assert_request_response(response)
      assert %{success: 1, failure: 0} = Oban.drain_queue(queue: :mail)
      assert_receive {:email, message}
      assert message.to == [{"", email}]
      [_, token] = Regex.run(~r{/magic_link/([^\s]+)}, message.text_body)
      {:ok, claims} = AshAuthentication.Jwt.peek(token)

      logs =
        capture_auth_log(fn ->
          page = get(recycle(response), "/magic_link/" <> token)
          markup = html_response(page, 200)
          assert markup =~ "Signing you in"
          assert markup =~ "phx-trigger-action"
          assert markup =~ ~s(name="user[remember_me]" value="true")
          assert markup =~ ~s(name="user[token]")
          assert [_] = magic_link_tokens(claims["jti"])
          refute get_session(page, :user_token)
          assert users_for(email) == users_before

          signed_in = post(recycle(page), @sign_in_path, user: %{token: token, remember_me: true})
          assert redirected_to(signed_in) == "/settings"
          refute get_session(signed_in, :return_to)
          [user] = users_for(email)
          if previous, do: assert(user.id == previous.id)
          login_token = get_session(signed_in, :user_token)
          assert {:ok, jti, _} = Login.verify(login_token, user)
          remember = AshAuthentication.Info.strategy!(User, :remember_me)

          assert %{secure: true, http_only: true, max_age: max_age} =
                   signed_in.resp_cookies[to_string(remember.cookie_name)]

          assert max_age > 0
          refute Security.passkey_verified?(jti, user.id)
          assert [%{primary_at: %DateTime{}}] = Ledger.read!(Verification, id: jti)
          assert [] == magic_link_tokens(claims["jti"])

          replay = post(build_conn(), @sign_in_path, user: %{token: token, remember_me: true})
          assert redirected_to(replay) == "/sign-in"
          assert Phoenix.Flash.get(replay.assigns.flash, :error) == "Incorrect email or password"
          refute get_session(replay, :user_token)
          refute replay.resp_cookies[to_string(remember.cookie_name)]
          assert [%{id: id}] = users_for(email)
          assert id == user.id
        end)

      refute logs =~ token
      refute logs =~ email
      assert logs =~ "auth.signed_in"
      assert logs =~ "auth.sign_in_failed"
    end
  end

  @spec capture_auth_log((-> term())) :: String.t()
  defp capture_auth_log(fun) do
    level = Logger.level()
    Logger.configure(level: :debug)

    try do
      capture_log([metadata: [:event]], fun)
    after
      Logger.configure(level: level)
    end
  end

  @spec users_for(String.t()) :: [User.t()]
  defp users_for(email) do
    Ash.read!(User, authorize?: false)
    |> Enum.filter(&(String.downcase(to_string(&1.email)) == String.downcase(email)))
  end

  @spec request(String.t()) :: Plug.Conn.t()
  defp request(email) do
    build_conn()
    |> init_test_session(%{return_to: "/settings"})
    |> post(@request_path, user: %{email: email})
  end

  @spec magic_link_tokens(String.t()) :: [Token.t()]
  defp magic_link_tokens(jti) do
    {:ok, tokens} =
      AshAuthentication.TokenResource.Actions.get_token(Token, %{
        "jti" => jti,
        "purpose" => "magic_link"
      })

    tokens
  end

  @spec assert_request_response(Plug.Conn.t()) :: :ok
  defp assert_request_response(response) do
    assert redirected_to(response) == "/sign-in"
    assert Phoenix.Flash.get(response.assigns.flash, :info) == @feedback
    refute Phoenix.Flash.get(response.assigns.flash, :error)
    assert get_session(response, :return_to) == "/settings"
    refute get_session(response, :user_token)
    :ok
  end
end
