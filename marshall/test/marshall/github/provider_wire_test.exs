defmodule Marshall.GitHub.ProviderWireTest do
  use ExUnit.Case, async: false
  alias Marshall.GitHub.{Grant, Provider}

  @client_id "synthetic-oauth-client"
  @secret "synthetic-oauth-secret"
  @redirect_uri "https://marshall.example.test/auth/github-com/callback"

  setup {Req.Test, :verify_on_exit!}

  setup do
    directory =
      Path.join(System.tmp_dir!(), "github-provider-#{System.unique_integer([:positive])}")

    File.mkdir!(directory)
    File.chmod!(directory, 0o700)
    secret_file = Path.join(directory, "client-secret")
    File.write!(secret_file, @secret)
    File.chmod!(secret_file, 0o600)

    config = [
      github_client_id: @client_id,
      github_client_secret_file: secret_file,
      github_redirect_uri: @redirect_uri
    ]

    original = Enum.map(config, fn {key, _} -> {key, Application.fetch_env(:marshall, key)} end)
    original_req = Application.fetch_env(:req, :default_options)

    on_exit(fn ->
      for {key, value} <- original, do: restore_env(:marshall, key, value)
      restore_env(:req, :default_options, original_req)
      File.rm_rf!(directory)
    end)

    for {key, value} <- config, do: Application.put_env(:marshall, key, value)
    Req.default_options(plug: {Req.Test, __MODULE__})
    :ok
  end

  # @cc [owner:ghuntley,label:verification;protocol] oauth-app-expiring-wire-conformance
  # The production provider MUST request offline_access with the accepted personal
  # scopes and PKCE, and exchange/refresh only through GitHub's documented fixed
  # endpoint. Fixtures MUST retain the documented eight-hour/six-month reply shape,
  # including offline_access absent from returned scopes. This is not live consent.
  test "documented OAuth App authorization, exchange and refresh preserve the rotating grant" do
    uri = Provider.authorization_url("synthetic-state", "synthetic-challenge") |> URI.parse()
    assert {uri.scheme, uri.host, uri.path} == {"https", "github.com", "/login/oauth/authorize"}
    query = URI.decode_query(uri.query)
    assert query["client_id"] == @client_id
    assert query["redirect_uri"] == @redirect_uri
    assert query["state"] == "synthetic-state"
    assert query["code_challenge"] == "synthetic-challenge"
    assert query["code_challenge_method"] == "S256"

    assert query["scope"] |> String.split() |> Enum.sort() ==
             Enum.sort(
               ~w(repo workflow read:org project gist notifications read:user user:email read:packages write:packages offline_access)
             )

    owner = self()

    Req.Test.expect(__MODULE__, fn conn ->
      assert_token_endpoint(conn)
      {body, conn} = form(conn)

      assert body == %{
               "client_id" => @client_id,
               "client_secret" => @secret,
               "code" => "synthetic-code",
               "code_verifier" => "synthetic-verifier",
               "redirect_uri" => @redirect_uri
             }

      send(owner, :exchange_observed)
      Req.Test.json(conn, documented_grant("first"))
    end)

    assert {:ok, %Grant{} = first} = Provider.exchange("synthetic-code", "synthetic-verifier")
    assert_receive :exchange_observed
    assert first.expires_in == 28_800
    assert first.refresh_expires_in == 15_897_600
    refute "offline_access" in first.scopes
    assert Provider.sufficient_scopes?(first.scopes)

    Req.Test.expect(__MODULE__, fn conn ->
      assert_token_endpoint(conn)
      {body, conn} = form(conn)

      assert body == %{
               "client_id" => @client_id,
               "client_secret" => @secret,
               "grant_type" => "refresh_token",
               "refresh_token" => first.refresh_token
             }

      send(owner, :refresh_observed)
      Req.Test.json(conn, documented_grant("second"))
    end)

    assert {:ok, second} = Provider.refresh(first.refresh_token)
    assert_receive :refresh_observed
    refute first.access_token == second.access_token
    refute first.refresh_token == second.refresh_token
    assert second.scopes == first.scopes
  end

  test "token errors, incomplete pairs and non-bearer authority cannot become grants" do
    for body <- [
          %{"error" => "bad_refresh_token"},
          %{"access_token" => "synthetic-access", "token_type" => "bearer", "scope" => "repo"},
          Map.delete(documented_grant("missing"), "token_type"),
          Map.put(documented_grant("wrong"), "token_type", "mac"),
          Map.delete(documented_grant("incomplete"), "refresh_token"),
          Map.drop(documented_grant("nonexpiring"), ["expires_in", "refresh_token_expires_in"])
        ] do
      Req.Test.expect(__MODULE__, &Req.Test.json(&1, body))
      assert {:error, reason} = Provider.refresh("synthetic-refresh")
      assert reason in [:invalid_response, :unavailable]
    end
  end

  test "redirects and transient failures never replay a token exchange" do
    owner = self()

    for status <- [302, 307, 429, 500, 503] do
      Req.Test.stub(__MODULE__, fn conn ->
        send(owner, {:token_attempt, status})

        conn
        |> Plug.Conn.put_resp_header("location", "https://unreviewed.example.test/token")
        |> Plug.Conn.send_resp(status, "")
      end)

      assert {:error, :unavailable} = Provider.exchange("synthetic-code", "synthetic-verifier")
      assert_receive {:token_attempt, ^status}
      refute_receive {:token_attempt, ^status}, 0
    end
  end

  @spec documented_grant(String.t()) :: %{String.t() => String.t() | pos_integer()}
  defp documented_grant(generation) do
    %{
      "access_token" => "synthetic-access-#{generation}",
      "refresh_token" => "synthetic-refresh-#{generation}",
      "expires_in" => 28_800,
      "refresh_token_expires_in" => 15_897_600,
      "scope" => "repo,workflow,read:org,project,gist,notifications,user,write:packages",
      "token_type" => "bearer"
    }
  end

  @spec assert_token_endpoint(Plug.Conn.t()) :: :ok
  defp assert_token_endpoint(conn) do
    assert {conn.method, conn.scheme, conn.host, conn.request_path} ==
             {"POST", :https, "github.com", "/login/oauth/access_token"}

    assert conn.query_string == ""
    assert Plug.Conn.get_req_header(conn, "accept") == ["application/json"]
    assert Plug.Conn.get_req_header(conn, "authorization") == []
    :ok
  end

  @spec form(Plug.Conn.t()) :: {%{String.t() => String.t()}, Plug.Conn.t()}
  defp form(conn) do
    {:ok, body, conn} = Plug.Conn.read_body(conn)
    {URI.decode_query(body), conn}
  end

  @spec restore_env(atom(), atom(), {:ok, term()} | :error) :: :ok
  defp restore_env(app, key, {:ok, value}), do: Application.put_env(app, key, value)
  defp restore_env(app, key, :error), do: Application.delete_env(app, key)
end
