defmodule MarshallWeb.AudiLoginControllerTest do
  use MarshallWeb.ConnCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.TerminalFixtures
  import ExUnit.CaptureLog
  alias Marshall.Authorization.SystemActor
  alias Marshall.Compute.Ledger
  alias Marshall.Ingress
  alias Audi.HTTP.Browser
  @fixtures Path.expand("../fixtures/tls", __DIR__)

  setup context do
    fixture = terminal_fixture(%{profile: Map.get(context, :profile, :standard)})

    previous =
      Map.new([:ingress_zone, :ingress_https_port], &{&1, Application.get_env(:marshall, &1)})

    Application.put_env(:marshall, :ingress_zone, "apps.example.test")
    Application.put_env(:marshall, :ingress_https_port, 8443)

    on_exit(fn ->
      for {key, value} <- previous do
        if is_nil(value),
          do: Application.delete_env(:marshall, key),
          else: Application.put_env(:marshall, key, value)
      end
    end)

    {service_token, _} = Ingress.Token.issue()

    {:ok, _} =
      Ingress.configure_service(
        %{
          name: "browser-" <> Ash.UUID.generate(),
          role: :gateway,
          host_id: fixture.vm.host_id,
          token: service_token,
          addresses: ["192.0.2.9"]
        },
        actor: SystemActor.compute()
      )

    {key, _} = :crypto.generate_key(:eddsa, :ed25519)
    public = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, key::binary>>)

    {:ok, _} =
      Ingress.publish_host_key(%{token: service_token, public_key: public},
        actor: SystemActor.compute()
      )

    server =
      start_supervised!(
        {Bandit,
         plug: MarshallWeb.ControlAPI,
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         certfile: Path.join(@fixtures, "localhost.pem"),
         keyfile: Path.join(@fixtures, "localhost.key")}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    {:ok, client} =
      Audi.Control.Client.new("https://127.0.0.1:#{port}", service_token, :gateway,
        host_id: fixture.vm.host_id,
        cacertfile: Path.join(@fixtures, "ca.pem")
      )

    client = Marshall.AudiControl.connect(client)

    [endpoint] = Ledger.read!(Ingress.Endpoint, vm_id: fixture.vm.id)
    Map.merge(fixture, %{client: client, endpoint: endpoint, service_token: service_token})
  end

  @tag profile: :customer
  test "actual HTTPS client cannot open Customer web or browser authorization", c do
    Ledger.update!(c.endpoint, :change_policy, %{visibility: :public, policy_revision: 2})

    for port <- [0, 3000, 9999] do
      assert {:error, _} = Audi.Control.Client.open_web(c.client, c.endpoint.label, port, nil)
    end

    hostname = c.endpoint.label <> ".apps.example.test"

    response =
      Browser.start(
        Plug.Test.conn(:get, "https://#{hostname}:8443/"),
        c.client,
        "apps.example.test",
        "https://control.example.test"
      )

    refute response.status in [200, 302, 303]
    refute Map.has_key?(response.resp_cookies, "__Host-audi_state")
  end

  @tag :hegel
  test "browser state, controller approval and HTTPS redemption produce a host-only app credential",
       c do
    check all(app_port <- member_of([0, 3000, 9999]), test_cases: 4) do
      [host] = Ledger.read!(Marshall.Compute.Host, id: c.vm.host_id)
      Ledger.update!(host, :report, %{reported_at: Ledger.now()})
      prefix = if app_port == 0, do: "", else: "p#{app_port}-"
      hostname = prefix <> c.endpoint.label <> ".apps.example.test"

      start =
        Browser.start(
          Plug.Test.conn(:get, "https://#{hostname}:8443/path?view=one"),
          c.client,
          "apps.example.test",
          "https://control.example.test"
        )

      assert start.status == 303
      [location] = get_resp_header(start, "location")
      assert URI.parse(location).host == "control.example.test"
      approval_path = URI.parse(location).path
      state = start.resp_cookies["__Host-audi_state"].value
      return = start.resp_cookies["__Host-audi_return"].value
      anonymous = get(build_conn(), approval_path)
      assert redirected_to(anonymous) == "/sign-in"
      assert get_session(anonymous, :return_to) == approval_path

      signed = signed_in(c.owner)

      approved =
        signed |> put_req_header("x-forwarded-host", "attacker.example") |> get(approval_path)

      assert approved.status == 302
      [callback] = get_resp_header(approved, "location")
      uri = URI.parse(callback)
      assert uri.scheme == "https" and uri.host == hostname and uri.port == 8443
      assert uri.path == "/_audi/callback"
      assert get_resp_header(approved, "cache-control") == ["no-store"]
      assert get_resp_header(approved, "referrer-policy") == ["no-referrer"]

      bad =
        Plug.Test.conn(:get, callback)
        |> put_req_header(
          "cookie",
          "__Host-audi_state=" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
        )
        |> Browser.callback(c.client)

      assert bad.status == 403
      refute Map.has_key?(bad.resp_cookies, "__Host-audi_session")

      callback_conn =
        Plug.Test.conn(:get, callback)
        |> put_req_header("cookie", "__Host-audi_state=#{state}; __Host-audi_return=#{return}")

      completed = Browser.callback(callback_conn, c.client)
      assert completed.status == 303
      assert get_resp_header(completed, "location") == ["/path?view=one"]
      cookie = completed.resp_cookies["__Host-audi_session"]
      assert cookie.secure and cookie.http_only and cookie.path == "/"
      assert cookie.same_site == "Lax" and Map.get(cookie, :domain) == nil

      assert {:ok, stream} =
               Audi.Control.Client.open_web(c.client, c.endpoint.label, app_port, cookie.value)

      assert stream.user_id == c.owner.id
      assert {:ok, _} = Audi.Control.Client.renew_web(c.client, stream.ticket, stream)
      assert Browser.callback(callback_conn, c.client).status == 403

      login_token = get_session(signed, "user_token")
      :ok = AshAuthentication.TokenResource.Actions.revoke(Marshall.Accounts.Token, login_token)
      assert {:error, _} = Audi.Control.Client.renew_web(c.client, stream.ticket, stream)

      assert {:error, :authentication_required} =
               Audi.Control.Client.open_web(c.client, c.endpoint.label, app_port, cookie.value)

      assert {:ok, %{closed: true}} = Audi.Control.Client.close_web(c.client, stream.ticket)
    end
  end

  test "malformed tickets cannot establish a return URL", c do
    response =
      get(signed_in(c.owner), "/audi/authorize/not-a-ticket?return_to=https://attacker.example")

    assert response.status == 404
    assert get_session(response, :return_to) == nil
  end

  test "denied exchanges emit a structured denial without ticket, code or state secrets", c do
    [host] = Ledger.read!(Marshall.Compute.Host, id: c.vm.host_id)
    Ledger.update!(host, :report, %{reported_at: Ledger.now()})
    hostname = c.endpoint.label <> ".apps.example.test"

    start =
      Browser.start(
        Plug.Test.conn(:get, "https://#{hostname}:8443/path?view=one"),
        c.client,
        "apps.example.test",
        "https://control.example.test"
      )

    assert start.status == 303
    [location] = get_resp_header(start, "location")
    approval_path = URI.parse(location).path
    state = start.resp_cookies["__Host-audi_state"].value

    approved = signed_in(c.owner) |> get(approval_path)
    assert approved.status == 302
    [callback] = get_resp_header(approved, "location")

    callback_conn =
      Plug.Test.conn(:get, callback)
      |> put_req_header(
        "cookie",
        "__Host-audi_state=" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
      )

    logs =
      capture_log([metadata: [:event]], fn ->
        assert Browser.callback(callback_conn, c.client).status == 403
      end)

    assert logs =~ "event=audi.web_login_denied"
    assert logs =~ "Authentication process diagnostic (payload redacted)"
    refute String.contains?(logs, state)
    refute String.contains?(logs, URI.parse(callback).query || "")
    refute String.contains?(logs, c.service_token)
  end

  defp signed_in(user) do
    user = Ash.Resource.put_metadata(user, :token, user_token(user))

    build_conn()
    |> init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
