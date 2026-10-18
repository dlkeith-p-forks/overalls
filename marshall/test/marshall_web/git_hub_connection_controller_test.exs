defmodule MarshallWeb.GitHubConnectionControllerTest do
  use MarshallWeb.ConnCase, async: false
  import ExUnit.CaptureLog

  test "browser connection preserves Marshall identity and consumes callback state once", %{
    conn: conn
  } do
    values = %{
      github_client_id: "synthetic-client",
      github_client_secret_file: "/unused-test-secret",
      github_redirect_uri: "https://example.test/auth/github-com/callback",
      github_provider: Marshall.GitHubTestProvider
    }

    originals = Map.new(values, fn {key, _} -> {key, Application.fetch_env(:marshall, key)} end)
    Enum.each(values, fn {key, value} -> Application.put_env(:marshall, key, value) end)

    on_exit(fn ->
      Enum.each(originals, fn
        {key, {:ok, value}} -> Application.put_env(:marshall, key, value)
        {key, :error} -> Application.delete_env(:marshall, key)
      end)
    end)

    owner = Marshall.ComputeFixtures.user()
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(owner)
    owner = Ash.Resource.put_metadata(owner, :token, token)

    conn =
      conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(owner)

    started = post(conn, "/auth/github-com/start", %{})
    location = redirected_to(started)
    assert URI.parse(location).host == "github.com"
    state = URI.decode_query(URI.parse(location).query)["state"]

    response =
      get(recycle(started), "/auth/github-com/callback", %{
        "state" => state,
        "code" => "synthetic-code"
      })

    assert redirected_to(response) == "/integrations"
    assert get_session(response, "user_token") == token
    assert get_resp_header(response, "referrer-policy") == ["no-referrer"]
    assert_receive {:exchanged, "synthetic-code", _verifier}

    repeated =
      get(recycle(response), "/auth/github-com/callback", %{
        "state" => state,
        "code" => "synthetic-code"
      })

    assert redirected_to(repeated) == "/integrations"
    refute_receive {:exchanged, _, _}
    refute inspect(get_session(repeated)) =~ state
  end

  test "callback requires stored login and never reflects OAuth inputs", %{conn: conn} do
    marker = "oauth-private-" <> Ash.UUID.generate()
    previous_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: previous_level) end)

    logs =
      capture_log(fn ->
        response = get(conn, "/auth/github-com/callback", %{"code" => marker, "state" => marker})
        assert redirected_to(response) == "/sign-in"
        assert get_resp_header(response, "cache-control") == ["no-store"]
        assert get_resp_header(response, "referrer-policy") == ["no-referrer"]
        refute response.resp_body =~ marker
      end)

    refute logs =~ marker
  end

  test "malformed provider callback returns to a clean page without provider descriptions", %{
    conn: conn
  } do
    marker = "oauth-description-" <> Ash.UUID.generate()
    response = get(conn, "/auth/github-com/callback", %{"error_description" => marker})
    assert redirected_to(response) == "/integrations"
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert get_resp_header(response, "referrer-policy") == ["no-referrer"]
    refute response.resp_body =~ marker
    refute inspect(get_session(response)) =~ marker
  end

  test "connection start requires a live stored login", %{conn: conn} do
    assert redirected_to(post(conn, "/auth/github-com/start", %{})) == "/sign-in"

    owner = Marshall.ComputeFixtures.user()
    {:ok, token, _} = AshAuthentication.Jwt.token_for_user(owner)
    owner = Ash.Resource.put_metadata(owner, :token, token)

    conn =
      conn |> init_test_session(%{}) |> AshAuthentication.Plug.Helpers.store_in_session(owner)

    {:ok, _jti, _} = Marshall.Accounts.Login.verify(token, owner)
    assert :ok = AshAuthentication.TokenResource.Actions.revoke(Marshall.Accounts.Token, token)
    response = post(conn, "/auth/github-com/start", %{})
    assert redirected_to(response) == "/sign-in"
  end
end
