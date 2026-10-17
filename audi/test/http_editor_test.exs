defmodule Audi.HTTP.EditorTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Plug.Conn
  alias Audi.HTTP.{Editor, EditorBrowser}
  alias OverallsProtocol.{EditorConnect, EditorName}
  @vm "01234567-89ab-4def-8123-456789abcdef"
  @host "11234567-89ab-4def-8123-456789abcdef"
  @account "21234567-89ab-4def-8123-456789abcdef"
  @fixtures Path.expand("../../marshall/test/fixtures/tls", __DIR__)

  setup do
    server =
      start_supervised!(
        {Bandit,
         plug: {Audi.Test.DNSControl, owner: self()},
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         certfile: Path.join(@fixtures, "localhost.pem"),
         keyfile: Path.join(@fixtures, "localhost.key")}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    {:ok, client} =
      Audi.Control.Client.new(
        "https://127.0.0.1:#{port}",
        "audi_service_" <> String.duplicate("A", 43),
        :gateway,
        host_id: @host,
        cacertfile: Path.join(@fixtures, "ca.pem")
      )

    %{client: Audi.Test.DNSControl.connected(client), label: EditorName.label(@vm, @account)}
  end

  property "unsafe requests reject sibling or missing origins before admission or connection",
           c do
    check all(
            method <- member_of([:post, :put, :delete]),
            suffix <- string(:alphanumeric, min_length: 1, max_length: 20)
          ) do
      conn = Plug.Test.conn(method, "https://#{c.label}.apps.test/upload", "private-canary")

      for origins <- [
            [],
            ["null"],
            ["https://#{suffix}.apps.test"],
            [Editor.origin(conn), Editor.origin(conn)]
          ] do
        conn = %{conn | req_headers: Enum.map(origins, &{"origin", &1})}

        response =
          Editor.call(conn,
            client: c.client,
            zone: "apps.test",
            connector: {Audi.Test.WebConnector, %{port: 1, owner: self()}}
          )

        assert response.status == 403
        assert get_resp_header(response, "x-frame-options") == ["DENY"]
        refute_received {:control_request, _, _, _, _, _}
        refute_received {:guest_binding, _}
      end

      assert Editor.origin_allowed?(put_req_header(conn, "origin", Editor.origin(conn)))

      refute Editor.origin_allowed?(
               put_req_header(
                 Plug.Test.conn(:get, "https://#{c.label}.apps.test/"),
                 "upgrade",
                 "websocket"
               )
             )
    end
  end

  test "editor credentials have a separate purpose and duplicate cookies are rejected", c do
    token = "audi_editor_cookie_" <> Base.url_encode64(<<0::256>>, padding: false)

    conn =
      Plug.Test.conn(:get, "https://#{c.label}.apps.test/")
      |> put_req_header("cookie", "__Host-audi_editor_session=" <> token)

    assert {:ok, ^token} = EditorBrowser.credential(conn)
    assert :error = Audi.HTTP.Browser.credential(conn)

    assert :error =
             EditorBrowser.credential(
               put_req_header(
                 conn,
                 "cookie",
                 "__Host-audi_editor_session=#{token}; __Host-audi_editor_session=#{token}"
               )
             )

    assert :error = EditorBrowser.target("e-malformed.apps.test", "apps.test")
    refute EditorBrowser.return_path?("/_editor/callback?code=secret")
  end

  test "browser login binds fresh state to the canonical personal origin", c do
    hostname = c.label <> ".apps.test"

    task =
      Task.async(fn ->
        Plug.Test.conn(:get, "https://#{hostname}/?folder=/home/alice")
        |> EditorBrowser.start(c.client, "apps.test", "https://marshall.test")
      end)

    assert_receive {:control_request, control, ref, "/api/audi/v1/editor-login-begin", _,
                    request},
                   2000

    assert Map.keys(request) |> Enum.sort() == ["label", "state_digest", "version"]
    assert request["label"] == c.label
    ticket = "audi_editor_login_" <> Base.url_encode64(<<1::256>>, padding: false)

    send(
      control,
      {ref, 200,
       JSON.encode!(%{
         version: 1,
         login: %{
           hostname: hostname,
           ticket: ticket,
           expires_at: DateTime.utc_now() |> DateTime.add(300) |> DateTime.to_iso8601()
         }
       })}
    )

    response = Task.await(task, 4000)

    assert get_resp_header(response, "location") == [
             "https://marshall.test/editor/authorize/" <> ticket
           ]

    state = response.resp_cookies["__Host-audi_editor_state"]
    assert state.http_only and state.secure and state.path == "/" and state.same_site == "Lax"

    assert Base.encode16(:crypto.hash(:sha256, state.value), case: :lower) ==
             request["state_digest"]

    refute Map.has_key?(state, :domain)
  end

  test "editor HTTP uses the exact account binding and strips authority before guest bytes", c do
    worker =
      "/stable-" <>
        String.duplicate("a", 40) <>
        "/static/out/vs/workbench/services/extensions/worker/webWorkerExtensionHostIframe.html"

    for {path, framing} <- [
          {"/", "DENY"},
          {worker, "SAMEORIGIN"},
          {String.replace(worker, String.duplicate("a", 40), String.duplicate("b", 40)), "DENY"},
          {worker <> "/other", "DENY"},
          {"/static/out/vs/workbench/services/extensions/worker/webWorkerExtensionHostIframe.html",
           "DENY"}
        ] do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      on_exit(fn -> :gen_tcp.close(listener) end)
      {:ok, {_, port}} = :inet.sockname(listener)
      owner = self()

      guest =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 3000)
          bytes = request(socket, "")
          send(owner, {:headers, bytes})

          :gen_tcp.send(
            socket,
            "HTTP/1.1 200 OK\r\nContent-Length: 2\r\nX-Frame-Options: DENY\r\nX-Frame-Options: SAMEORIGIN\r\nSet-Cookie: __Host-audi_editor_session=forged; Secure\r\n\r\nok"
          )

          :gen_tcp.close(socket)
        end)

      token = "audi_editor_cookie_" <> Base.url_encode64(<<0::256>>, padding: false)

      task =
        Task.async(fn ->
          Plug.Test.conn(:get, "https://#{c.label}.apps.test" <> path)
          |> put_req_header("cookie", "__Host-audi_editor_session=#{token}; app=ok")
          |> put_req_header("x-original-host", "forged.test")
          |> Editor.call(
            client: c.client,
            zone: "apps.test",
            connector: {Audi.Test.WebConnector, %{port: port, owner: owner}}
          )
        end)

      assert_receive {:control_request, control, ref, "/api/audi/v1/editor-open", _, request},
                     2000

      assert request["cookie"] == token
      binding = editor_binding(c.label)

      send(
        control,
        {ref, 200,
         JSON.encode!(%{
           version: 1,
           grant: %{
             binding: binding,
             user_id: @account,
             ttl: 5000,
             ticket: "audi_editor_stream_" <> Base.url_encode64(<<2::256>>, padding: false)
           }
         })}
      )

      assert_receive {:guest_binding, ^binding}, 2000
      assert_receive {:headers, headers}, 2000
      refute headers =~ token
      refute headers =~ "forged.test"
      assert headers =~ "app=ok"
      response = Task.await(task, 4000)
      assert response.status == 200
      assert get_resp_header(response, "x-frame-options") == [framing]
      assert get_resp_header(response, "set-cookie") == []
      Task.await(guest, 1000)
      assert_receive {:control_request, close, close_ref, "/api/audi/v1/editor-close", _, _}, 2000
      send(close, {close_ref, 200, JSON.encode!(%{version: 1, result: %{closed: true}})})
    end
  end

  @spec editor_binding(binary()) :: EditorConnect.binding()
  defp editor_binding(label),
    do: %{
      vm_id: @vm,
      host_id: @host,
      placement_id: @vm,
      session_id: @host,
      execution_epoch: 1,
      generation: 1,
      label: label,
      service: :editor,
      port: 4444,
      user_id: @account,
      guest_account_id: @account,
      uid: 200_000,
      username: "alice",
      editor_protocol: 1,
      editor_commit: String.duplicate("a", 40),
      editor_release: String.duplicate("b", 64),
      editor_origin: "https://#{label}.apps.test"
    }

  @spec request(port(), binary()) :: binary()
  defp request(socket, acc) do
    if String.contains?(acc, "\r\n\r\n"),
      do: acc,
      else:
        (
          {:ok, bytes} = :gen_tcp.recv(socket, 0, 2000)
          request(socket, acc <> bytes)
        )
  end
end
