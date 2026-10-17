defmodule Audi.HTTP.ProxyTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  import Plug.Conn
  alias Audi.Control.Client
  @fixtures Path.expand("../../marshall/test/fixtures/tls", __DIR__)
  @vm "01234567-89ab-4def-8123-456789abcdef"
  @host "11234567-89ab-4def-8123-456789abcdef"
  @label "demo-0123456789ab4def8123456789abcdef"

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
      Client.new(
        "https://127.0.0.1:#{port}",
        "audi_service_" <> String.duplicate("A", 43),
        :gateway,
        host_id: @host,
        cacertfile: Path.join(@fixtures, "ca.pem")
      )

    client = Audi.Test.DNSControl.connected(client)

    %{client: client}
  end

  test "browser sign-in redirects to the configured public origin", c do
    origin = "https://control.example.test"
    hostname = @label <> ".apps.example"
    ticket = "audi_web_login_" <> Base.url_encode64(<<0::256>>, padding: false)

    task =
      Task.async(fn ->
        Plug.Test.conn(:get, "https://#{hostname}/private")
        |> Audi.HTTP.Browser.start(c.client, "apps.example", origin)
      end)

    assert_receive {:control_request, control, ref, "/api/audi/v1/web-login-begin", _, _},
                   2000

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
    assert response.status == 303
    assert get_resp_header(response, "location") == [origin <> "/audi/authorize/" <> ticket]
    refute hd(get_resp_header(response, "location")) =~ c.client.origin
  end

  property "HTTPS-authorized HTTP streams bytes and removes platform authority from guest headers",
           c do
    check all(payload <- binary(min_length: 1, max_length: 80_000), max_runs: 5) do
      {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
      {:ok, {_, port}} = :inet.sockname(listener)
      owner = self()

      guest =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 3000)
          request = request(socket, "")
          send(owner, {:guest_headers, request})

          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 200 OK\r\nTransfer-Encoding: chunked\r\n",
              "Set-Cookie: __Host-audi_session=forged; Secure\r\n",
              "Set-Cookie: app=value; Domain=apps.example\r\n\r\n"
            ])

          for chunk <- chunks(payload),
              do:
                :ok =
                  :gen_tcp.send(socket, [
                    Integer.to_string(byte_size(chunk), 16),
                    "\r\n",
                    chunk,
                    "\r\n"
                  ])

          :ok = :gen_tcp.send(socket, "0\r\n\r\n")
          :gen_tcp.close(socket)
        end)

      task =
        Task.async(fn ->
          Plug.Test.conn(:get, "https://#{@label}.apps.example/path")
          |> put_req_header("cookie", "app=ok; __Host-audi_state=secret")
          |> put_req_header("x-forwarded-for", "forged")
          |> put_req_header("x-audi-user-id", @host)
          |> Audi.HTTP.Proxy.call(
            client: c.client,
            zone: "apps.example",
            connector: {Audi.Test.WebConnector, %{port: port, owner: owner}}
          )
        end)

      assert_receive {:control_request, control, ref, "/api/audi/v1/web-open", _, request}, 2000
      assert request["app_port"] == 0
      assert request["cookie"] == nil
      send(control, {ref, 200, JSON.encode!(grant())})
      assert_receive {:guest_binding, %{service: :web, port: 8080, host_id: @host}}, 2000
      assert_receive {:guest_headers, headers}, 2000
      refute headers =~ "secret"
      refute headers =~ "forged"
      refute headers =~ "x-audi-user-id"
      assert headers =~ "app=ok"
      response = Task.await(task, 4000)
      assert response.status == 200
      assert IO.iodata_to_binary(response.resp_body) == payload
      assert get_resp_header(response, "set-cookie") == ["app=value"]
      Task.await(guest, 1000)
      assert_receive {:control_request, close, close_ref, "/api/audi/v1/web-close", _, _}, 2000
      send(close, {close_ref, 200, JSON.encode!(%{version: 1, result: %{closed: true}})})
      :gen_tcp.close(listener)
    end
  end

  defmodule Upload do
    @behaviour Plug
    def init(options), do: options
    def call(conn, _), do: consume(conn, :crypto.hash_init(:sha256))

    defp consume(conn, digest) do
      case Plug.Conn.read_body(conn, length: 8192, read_length: 8192) do
        {:more, bytes, conn} ->
          consume(conn, :crypto.hash_update(digest, bytes))

        {:ok, bytes, conn} ->
          checksum =
            digest |> :crypto.hash_update(bytes) |> :crypto.hash_final() |> Base.encode16()

          Plug.Conn.send_resp(conn, 200, checksum)
      end
    end
  end

  property "binary uploads preserve bytes across bounded upstream chunks", c do
    upstream =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit, plug: Upload, scheme: :http, ip: {127, 0, 0, 1}, port: 0, startup_log: false},
          id: :upload_guest
        )
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(upstream)
    owner = self()

    check all(payload <- binary(min_length: 65_537, max_length: 200_000), max_runs: 5) do
      task =
        Task.async(fn ->
          Plug.Test.conn(:post, "https://#{@label}.apps.example/upload", payload)
          |> Audi.HTTP.Proxy.call(
            client: c.client,
            zone: "apps.example",
            connector: {Audi.Test.WebConnector, %{port: port, owner: owner}}
          )
        end)

      assert_receive {:control_request, control, ref, "/api/audi/v1/web-open", _, _}, 2000
      send(control, {ref, 200, JSON.encode!(grant())})
      response = Task.await(task, 4000)
      assert response.status == 200

      assert IO.iodata_to_binary(response.resp_body) ==
               Base.encode16(:crypto.hash(:sha256, payload))

      assert_receive {:control_request, close, close_ref, "/api/audi/v1/web-close", _, _}, 2000
      send(close, {close_ref, 200, JSON.encode!(%{version: 1, result: %{closed: true}})})
    end
  end

  test "peer authorization is verified before connection and replaced by trusted provenance", c do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_, port}} = :inet.sockname(listener)
    owner = self()
    token = "galileo_peer_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    guest =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 3000)
        request = request(socket, "")
        send(owner, {:peer_guest_headers, request})
        :ok = :gen_tcp.send(socket, "HTTP/1.1 204 No Content\r\nContent-Length: 0\r\n\r\n")
        :gen_tcp.close(socket)
      end)

    task =
      Task.async(fn ->
        Plug.Test.conn(:get, "https://#{@label}.apps.example/path")
        |> put_req_header("authorization", "galileo-peer " <> token)
        |> put_req_header("x-overalls-source-vm", @host)
        |> Audi.HTTP.Proxy.call(
          client: c.client,
          zone: "apps.example",
          connector: {Audi.Test.WebConnector, %{port: port, owner: owner}}
        )
      end)

    assert_receive {:control_request, control, ref, "/api/audi/v1/galileo-peer", _, request},
                   2000

    assert request == %{
             "peer_token" => token,
             "label" => @label,
             "app_port" => 0,
             "version" => 1
           }

    refute_received {:guest_binding, _}

    send(
      control,
      {ref, 200,
       JSON.encode!(%{
         version: 1,
         grant: grant().grant,
         attestation: %{
           purpose: "galileo-peer",
           source_vm_id: @vm,
           name: "exedev",
           expires_at: System.system_time(:second) + 30
         }
       })}
    )

    assert_receive {:peer_guest_headers, headers}, 2000
    refute String.downcase(headers) =~ "authorization:"
    refute headers =~ @host
    assert headers =~ "x-overalls-source-vm: #{@vm}\r\n"
    assert Task.await(task, 4000).status == 204
    Task.await(guest, 1000)

    assert_receive {:control_request, close, close_ref, "/api/audi/v1/web-close", _, _}, 2000
    send(close, {close_ref, 200, JSON.encode!(%{version: 1, result: %{closed: true}})})
  end

  test "invalid peer authorization is denied without downgrade or guest connection", c do
    response =
      Plug.Test.conn(:post, "https://#{@label}.apps.example/path", "must-not-forward")
      |> put_req_header("authorization", "galileo-peer malformed")
      |> Audi.HTTP.Proxy.call(
        client: c.client,
        zone: "apps.example",
        connector: {Audi.Test.WebConnector, %{port: 1, owner: self()}}
      )

    assert response.status == 403
    refute_received {:control_request, _, _, _, _, _}
    refute_received {:guest_binding, _}
  end

  test "peer verification outage fails closed before guest connection or body forwarding", c do
    token = "galileo_peer_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    task =
      Task.async(fn ->
        Plug.Test.conn(:post, "https://#{@label}.apps.example/path", "must-not-forward")
        |> put_req_header("authorization", "galileo-peer " <> token)
        |> Audi.HTTP.Proxy.call(
          client: c.client,
          zone: "apps.example",
          connector: {Audi.Test.WebConnector, %{port: 1, owner: self()}}
        )
      end)

    assert_receive {:control_request, control, ref, "/api/audi/v1/galileo-peer", _, _}, 2000
    send(control, {ref, 503, JSON.encode!(%{error: "temporarily_unavailable"})})

    assert Task.await(task, 4000).status == 503
    refute_received {:guest_binding, _}
    refute_received {:control_request, _, _, "/api/audi/v1/web-open", _, _}
  end

  defmodule Relay do
    @behaviour Plug
    def init(options), do: options

    def call(conn, options),
      do:
        conn |> Plug.Conn.put_resp_header("connection", "close") |> Audi.HTTP.Proxy.call(options)
  end

  property "truncated guest bodies cannot become successfully terminated HTTP responses", c do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    on_exit(fn -> :gen_tcp.close(listener) end)
    {:ok, {_, guest_port}} = :inet.sockname(listener)
    owner = self()

    proxy =
      start_supervised!(
        {Bandit,
         plug:
           {Relay,
            client: c.client,
            zone: "apps.example",
            connector: {Audi.Test.WebConnector, %{port: guest_port, owner: owner}}},
         scheme: :http,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         http_options: [log_exceptions_with_status_codes: []]}
      )

    {:ok, {_, proxy_port}} = ThousandIsland.listener_info(proxy)

    check all(payload <- string(:alphanumeric, min_length: 1, max_length: 4096), max_runs: 5) do
      guest =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 3000)
          request(socket, "")

          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 200 OK\r\nContent-Length: ",
              Integer.to_string(byte_size(payload) + 100),
              "\r\n\r\n",
              payload
            ])

          receive do
            :truncate -> :gen_tcp.close(socket)
          after
            3000 -> flunk("client did not receive response headers")
          end
        end)

      client =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, proxy_port, [:binary, active: false])
          :ok = :gen_tcp.send(socket, "GET / HTTP/1.1\r\nHost: #{@label}.apps.example\r\n\r\n")
          initial = request(socket, "")
          send(guest.pid, :truncate)
          response = closed_response(socket, initial)
          :gen_tcp.close(socket)
          response
        end)

      assert_receive {:control_request, control, ref, "/api/audi/v1/web-open", _, _}, 2000
      send(control, {ref, 200, JSON.encode!(grant())})
      response = Task.await(client, 4000)
      assert response =~ "HTTP/1.1 200"
      refute String.ends_with?(response, "0\r\n\r\n")
      refute response =~ "HTTP/1.1 502"
      Task.await(guest, 1000)
      assert_receive {:control_request, close, close_ref, "/api/audi/v1/web-close", _, _}, 2000
      send(close, {close_ref, 200, JSON.encode!(%{version: 1, result: %{closed: true}})})
    end
  end

  defp closed_response(socket, acc) do
    case :gen_tcp.recv(socket, 0, 2000) do
      {:ok, bytes} -> closed_response(socket, acc <> bytes)
      {:error, :closed} -> acc
      other -> flunk("response did not close: #{inspect(other)}")
    end
  end

  property "WebSocket handshakes and masked messages traverse the authorized guest connection",
           c do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, guest_port}} = :inet.sockname(listener)
    owner = self()

    proxy =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug:
             {Relay,
              client: c.client,
              zone: "apps.example",
              connector: {Audi.Test.WebConnector, %{port: guest_port, owner: owner}}},
           scheme: :http,
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false,
           websocket_options: [
             compress: false,
             max_frame_size: 1_048_576,
             max_fragmented_message_size: 1_048_576
           ]},
          id: :websocket_proxy
        )
      )

    {:ok, {_, proxy_port}} = ThousandIsland.listener_info(proxy)

    check all(payload <- binary(min_length: 1, max_length: 125), max_runs: 4) do
      guest =
        Task.async(fn ->
          {:ok, socket} = :gen_tcp.accept(listener, 3000)
          headers = request(socket, "")

          [key] =
            Regex.run(~r/sec-websocket-key: ([^\r]+)\r\n/i, headers, capture: :all_but_first)

          accept =
            Base.encode64(:crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))

          :ok =
            :gen_tcp.send(socket, [
              "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: ",
              accept,
              "\r\n\r\n"
            ])

          {:ok, <<0x82, 1::1, size::7>>} = :gen_tcp.recv(socket, 2, 2000)
          {:ok, <<mask::binary-size(4), encoded::binary>>} = :gen_tcp.recv(socket, size + 4, 2000)
          repeated = binary_part(:binary.copy(mask, div(size + 3, 4)), 0, size)
          assert :crypto.exor(encoded, repeated) == payload
          :ok = :gen_tcp.send(socket, <<0x82, size, payload::binary>>)
          :gen_tcp.close(socket)
        end)

      client =
        Task.async(fn ->
          {:ok, socket} =
            :gen_tcp.connect({127, 0, 0, 1}, proxy_port, [:binary, active: false], 1000)

          key = Base.encode64(:crypto.strong_rand_bytes(16))

          :ok =
            :gen_tcp.send(socket, [
              "GET /ws HTTP/1.1\r\nHost: ",
              @label,
              ".apps.example\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ",
              key,
              "\r\n\r\n"
            ])

          headers = request(socket, "")
          assert headers =~ "101"

          expected =
            Base.encode64(:crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))

          assert String.downcase(headers) =~ String.downcase("sec-websocket-accept: " <> expected)
          {:ok, frame} = Audi.HTTP.WebSocketFrame.encode(:binary, payload)
          :ok = :gen_tcp.send(socket, frame)
          {:ok, <<0x82, size>>} = :gen_tcp.recv(socket, 2, 2000)
          {:ok, received} = :gen_tcp.recv(socket, size, 2000)
          :gen_tcp.close(socket)
          received
        end)

      assert_receive {:control_request, control, ref, "/api/audi/v1/web-open", _, _}, 2000
      send(control, {ref, 200, JSON.encode!(grant())})
      assert_receive {:guest_binding, %{service: :web}}, 2000
      assert Task.await(client, 4000) == payload
      Task.await(guest, 1000)
      assert_receive {:control_request, close, close_ref, "/api/audi/v1/web-close", _, _}, 2000
      send(close, {close_ref, 200, JSON.encode!(%{version: 1, result: %{closed: true}})})
    end

    :gen_tcp.close(listener)
  end

  # @cc [owner:ghuntley,label:verification;recovery] audi-websocket-idle-timeout-test
  # A quiet browser MUST NOT be closed by the listener's HTTP read_timeout:
  # with a 300 ms listener read_timeout, an upgraded socket idle for 1 s MUST
  # still deliver the guest's next frame.
  test "an idle upgraded WebSocket outlives the listener read timeout", c do
    {:ok, listener} = :gen_tcp.listen(0, [:binary, active: false, ip: {127, 0, 0, 1}])
    {:ok, {_, guest_port}} = :inet.sockname(listener)
    owner = self()

    proxy =
      start_supervised!(
        Supervisor.child_spec(
          {Bandit,
           plug:
             {Relay,
              client: c.client,
              zone: "apps.example",
              connector: {Audi.Test.WebConnector, %{port: guest_port, owner: owner}}},
           scheme: :http,
           ip: {127, 0, 0, 1},
           port: 0,
           startup_log: false,
           thousand_island_options: [read_timeout: 300],
           websocket_options: [compress: false]},
          id: :idle_websocket_proxy
        )
      )

    {:ok, {_, proxy_port}} = ThousandIsland.listener_info(proxy)

    guest =
      Task.async(fn ->
        {:ok, socket} = :gen_tcp.accept(listener, 3000)
        headers = request(socket, "")
        [key] = Regex.run(~r/sec-websocket-key: ([^\r]+)\r\n/i, headers, capture: :all_but_first)
        accept = Base.encode64(:crypto.hash(:sha, key <> "258EAFA5-E914-47DA-95CA-C5AB0DC85B11"))

        :ok =
          :gen_tcp.send(socket, [
            "HTTP/1.1 101 Switching Protocols\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Accept: ",
            accept,
            "\r\n\r\n"
          ])

        receive do
          :send -> :ok = :gen_tcp.send(socket, <<0x82, 4, "late">>)
        after
          5000 -> flunk("idle client never released the guest")
        end

        socket
      end)

    {:ok, socket} = :gen_tcp.connect({127, 0, 0, 1}, proxy_port, [:binary, active: false], 1000)
    key = Base.encode64(:crypto.strong_rand_bytes(16))

    :ok =
      :gen_tcp.send(socket, [
        "GET /ws HTTP/1.1\r\nHost: ",
        @label,
        ".apps.example\r\nConnection: Upgrade\r\nUpgrade: websocket\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Key: ",
        key,
        "\r\n\r\n"
      ])

    assert_receive {:control_request, control, ref, "/api/audi/v1/web-open", _, _}, 2000
    send(control, {ref, 200, JSON.encode!(grant(30_000))})
    assert request(socket, "") =~ "101"
    Process.sleep(1000)
    send(guest.pid, :send)
    assert {:ok, <<0x82, 4, "late">>} = :gen_tcp.recv(socket, 6, 2000)

    :gen_tcp.close(socket)
    :gen_tcp.close(Task.await(guest, 1000))
    assert_receive {:control_request, close, close_ref, "/api/audi/v1/web-close", _, _}, 2000
    send(close, {close_ref, 200, JSON.encode!(%{version: 1, result: %{closed: true}})})
    :gen_tcp.close(listener)
  end

  defp grant(ttl \\ 5000) do
    %{
      version: 1,
      grant: %{
        ttl: ttl,
        user_id: nil,
        ticket:
          "audi_web_stream_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false),
        binding: %{
          vm_id: @vm,
          host_id: @host,
          placement_id: @vm,
          session_id: @host,
          execution_epoch: 1,
          generation: 1,
          label: @label,
          service: "web",
          port: 8080
        }
      }
    }
  end

  defp request(socket, acc) do
    if String.contains?(acc, "\r\n\r\n"),
      do: acc,
      else:
        (
          {:ok, bytes} = :gen_tcp.recv(socket, 0, 2000)
          request(socket, acc <> bytes)
        )
  end

  defp chunks(<<chunk::binary-size(4096), rest::binary>>), do: [chunk | chunks(rest)]
  defp chunks(<<>>), do: []
  defp chunks(rest), do: [rest]
end
