defmodule MarshallWeb.EditorControllerTest do
  use MarshallWeb.ConnCase, async: false
  alias Marshall.EditorFixture, as: F

  setup do
    previous = Application.get_env(:marshall, :ingress_editor_releases)
    Application.put_env(:marshall, :ingress_editor_releases, F.releases())

    on_exit(fn ->
      if previous,
        do: Application.put_env(:marshall, :ingress_editor_releases, previous),
        else: Application.delete_env(:marshall, :ingress_editor_releases)
    end)

    F.new()
  end

  test "Open VS Code redirects through fresh authority to the account origin", c do
    response =
      signed_in(c.owner, c.token)
      |> put_req_header("x-forwarded-host", "attacker.example")
      |> get("/machines/#{c.vm.id}/code")

    assert response.status == 302
    [location] = get_resp_header(response, "location")
    uri = URI.parse(location)
    assert uri.scheme == "https" and uri.path == "/"
    label = String.replace_suffix(uri.host, ".apps.example.test", "")
    assert {:ok, %{vm_id: vm_id}} = OverallsProtocol.EditorName.parse(label)
    assert vm_id == c.vm.id
    assert get_resp_header(response, "cache-control") == ["no-store"]
    assert get_resp_header(response, "referrer-policy") == ["no-referrer"]
    :ok = AshAuthentication.TokenResource.Actions.revoke(Marshall.Accounts.Token, c.token)
    rejected = get(signed_in(c.owner, c.token), "/machines/#{c.vm.id}/code")

    refute rejected.status == 302 and
             String.starts_with?(
               List.first(get_resp_header(rejected, "location")) || "",
               "https://e-"
             )
  end

  test "anonymous launch retains only the fixed local sign-in return", c do
    response = get(build_conn(), "/machines/#{c.vm.id}/code?return_to=https://attacker.example")
    assert redirected_to(response) == "/sign-in"
    assert get_session(response, :return_to) == "/machines/#{c.vm.id}/code"
    malformed = get(build_conn(), "/editor/authorize/invalid?return_to=https://attacker.example")
    assert malformed.status == 404
    assert get_session(malformed, :return_to) == nil
  end

  test "approval targets the domain hostname and isolated editor callback", c do
    {login, _} = F.begin_login(c, F.label(c, c.owner))
    path = "/editor/authorize/" <> login.ticket
    anonymous = get(build_conn(), path)
    assert redirected_to(anonymous) == "/sign-in"
    assert get_session(anonymous, :return_to) == path
    approved = get(signed_in(c.owner, c.token), path)
    assert approved.status == 302
    [location] = get_resp_header(approved, "location")
    uri = URI.parse(location)
    assert uri.host == login.hostname and uri.path == "/_editor/callback"
    params = URI.decode_query(uri.query)
    assert params["ticket"] == login.ticket
    assert OverallsProtocol.EditorLogin.token?(params["code"], :code)
    assert get_resp_header(approved, "cache-control") == ["no-store"]
    assert get_resp_header(approved, "referrer-policy") == ["no-referrer"]
  end

  @spec signed_in(Marshall.Accounts.User.t(), String.t()) :: Plug.Conn.t()
  defp signed_in(user, token) do
    user = Ash.Resource.put_metadata(user, :token, token)

    build_conn()
    |> init_test_session(%{})
    |> AshAuthentication.Plug.Helpers.store_in_session(user)
  end
end
