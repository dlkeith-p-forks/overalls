defmodule MarshallWeb.RepositoryLaunchControllerTest do
  use MarshallWeb.ConnCase, async: false
  import Phoenix.LiveViewTest
  alias Marshall.Compute.{Ledger, VirtualMachine}
  alias MarshallWeb.{PendingLaunch, RepositoryLaunchController}
  alias Marshall.PasskeyFixture, as: Fixture

  @url "https://github.com/antithesishq/weaver"
  @visit String.duplicate("a", 32)

  test "anonymous staging canonicalizes public input and creates no machine", %{conn: conn} do
    baseline = length(Ledger.read!(VirtualMachine))

    conn =
      conn
      |> init_test_session(%{})
      |> RepositoryLaunchController.stage(%{
        "source" => @url <> "?token=discarded",
        "visit" => @visit,
        "expires_at" => 9_999_999_999,
        "return_to" => "https://evil.example"
      })

    assert redirected_to(conn) == "/launch"
    assert pending = get_session(conn, PendingLaunch.key())
    assert pending.source == @url
    assert_in_delta pending.expires_at, System.system_time(:second) + 1_800, 2
    assert length(Ledger.read!(VirtualMachine)) == baseline

    assert {:error, {:redirect, %{to: "/sign-in"}}} =
             live(
               put_session(build_conn() |> init_test_session(%{}), PendingLaunch.key(), pending),
               "/launch"
             )

    assert get_resp_header(conn, "cache-control") == ["no-store"]
  end

  test "staging route refuses a missing CSRF token", %{conn: conn} do
    assert_raise Plug.CSRFProtection.InvalidCSRFTokenError, fn ->
      conn
      |> put_private(:plug_skip_csrf_protection, false)
      |> post("/launch/pending", %{"source" => @url, "visit" => @visit})
    end
  end

  test "public capture posts a CSRF form into the signed session", %{conn: conn} do
    entry = get(conn, "/launch/entry")
    body = html_response(entry, 200)
    [_, csrf] = Regex.run(~r/name="_csrf_token"[^>]*value="([^"]+)"/, body)

    response =
      entry
      |> recycle()
      |> put_private(:plug_skip_csrf_protection, false)
      |> post("/launch/pending", %{"_csrf_token" => csrf, "source" => @url, "visit" => @visit})

    assert redirected_to(response) == "/launch"
    assert PendingLaunch.read(get_session(response))
    refute get_session(response, "user_token")
  end

  test "enrolled logins can open staged input while revoked logins are refused", %{conn: conn} do
    {actor, token} = Fixture.login(Fixture.user())
    Fixture.register(actor)
    {:ok, pending} = PendingLaunch.new(@url, @visit)
    signed = signed_in(conn, actor, token, pending)

    {:ok, view, _} = live(signed, "/launch")
    assert has_element?(view, "#main-content")

    assert Ledger.read!(VirtualMachine, owner_id: actor.id) == []
    :ok = Marshall.Accounts.AccountLifecycle.revoke_tokens!(actor.id)
    assert {:error, {:redirect, %{to: "/sign-in"}}} = live(signed, "/launch")
    assert Ledger.read!(VirtualMachine, owner_id: actor.id) == []
  end

  test "expired pending launch redirects without admission", %{conn: conn} do
    {actor, token} = Fixture.login(Fixture.user())
    {:ok, pending} = PendingLaunch.new(@url, @visit, System.system_time(:second) - 1_800)

    assert {:error, {:live_redirect, %{to: "/overview"}}} =
             live(signed_in(conn, actor, token, pending), "/launch")

    assert Ledger.read!(VirtualMachine, owner_id: actor.id) == []
  end

  # @cc [owner:ghuntley,label:verification;security] pending-authenticated-cookie-budget
  # A complete real browser session containing the largest supported source,
  # ordinary stored login, CSRF and return state MUST fit within a 4096-byte
  # serialized Set-Cookie header. Source bounds MUST NOT overflow after sign-in.
  test "largest accepted source plus full stored login fits the browser cookie budget" do
    {actor, token} = Fixture.login(Fixture.user())

    namespace =
      String.duplicate("n", 100) <>
        "/" <> String.duplicate("g", 100) <> "/" <> String.duplicate("h", 53)

    url =
      "https://gitlab.com/" <>
        namespace <> "/" <> String.duplicate("r", 100) <> "/-/tree/" <> String.duplicate("b", 255)

    assert {:ok, pending} = PendingLaunch.new(url, @visit)
    assert byte_size(pending.source) >= 630

    options = Plug.Session.init(MarshallWeb.BrowserSession.options())

    conn = %{build_conn() | secret_key_base: MarshallWeb.Endpoint.config(:secret_key_base)}

    conn =
      conn
      |> Plug.Session.call(options)
      |> fetch_session()
      |> put_session(:return_to, "/launch")
      |> put_session("_csrf_token", String.duplicate("c", 32))
      |> put_session(PendingLaunch.key(), pending)
      |> AshAuthentication.Plug.Helpers.store_in_session(
        Ash.Resource.put_metadata(actor, :token, token)
      )
      |> send_resp(200, "ok")

    [cookie] = get_resp_header(conn, "set-cookie")
    assert byte_size(cookie) < 4_096
  end

  @spec signed_in(Plug.Conn.t(), Marshall.Accounts.User.t(), String.t(), PendingLaunch.pending()) ::
          Plug.Conn.t()
  defp signed_in(conn, user, token, pending) do
    conn
    |> init_test_session(%{PendingLaunch.key() => pending})
    |> AshAuthentication.Plug.Helpers.store_in_session(
      Ash.Resource.put_metadata(user, :token, token)
    )
  end
end
