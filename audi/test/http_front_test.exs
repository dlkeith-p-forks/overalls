defmodule Audi.HTTP.FrontTest do
  use ExUnit.Case, async: true
  import Plug.Conn
  alias Audi.Control.Client
  @zone "apps.example"
  @label "demo-0123456789ab4def8123456789abcdef"
  @host @label <> "." <> @zone
  @browser_origin "https://control.example.test"

  setup_all do
    directory = Path.join(System.tmp_dir!(), "audi-front-#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    File.chmod!(directory, 0o700)
    on_exit(fn -> File.rm_rf!(directory) end)

    openssl = fn args ->
      {output, status} = System.cmd("openssl", args, cd: directory, stderr_to_stdout: true)
      assert status == 0, output
    end

    openssl.([
      "req",
      "-x509",
      "-newkey",
      "ec",
      "-pkeyopt",
      "ec_paramgen_curve:P-256",
      "-nodes",
      "-keyout",
      "root.key",
      "-out",
      "root.pem",
      "-subj",
      "/CN=front-root",
      "-days",
      "2",
      "-addext",
      "basicConstraints=critical,CA:TRUE",
      "-addext",
      "keyUsage=critical,keyCertSign,cRLSign"
    ])

    openssl.([
      "req",
      "-new",
      "-newkey",
      "ec",
      "-pkeyopt",
      "ec_paramgen_curve:P-256",
      "-nodes",
      "-keyout",
      "leaf.key",
      "-out",
      "leaf.csr",
      "-subj",
      "/CN=front-fixture"
    ])

    File.write!(
      Path.join(directory, "ext"),
      "basicConstraints=critical,CA:FALSE\nkeyUsage=critical,digitalSignature\nextendedKeyUsage=serverAuth\nsubjectAltName=DNS:*.#{@zone}\n"
    )

    openssl.([
      "x509",
      "-req",
      "-in",
      "leaf.csr",
      "-CA",
      "root.pem",
      "-CAkey",
      "root.key",
      "-CAcreateserial",
      "-days",
      "1",
      "-extfile",
      "ext",
      "-out",
      "leaf.pem"
    ])

    %{
      certificate_dir: directory,
      roots: File.read!(Path.join(directory, "root.pem")),
      chain: File.read!(Path.join(directory, "leaf.pem")),
      key: File.read!(Path.join(directory, "leaf.key"))
    }
  end

  setup %{roots: roots, chain: chain, key: key} do
    store = Audi.Test.TLSStore.start!(trust_pem: roots)

    assert {:ok, metadata} = Audi.TLS.Store.install_fleet(store, @zone, 1, chain, key)
    assert metadata.hostname == @zone

    server =
      start_supervised!(
        {Bandit,
         plug: {Audi.Test.DNSControl, owner: self()},
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         certfile: Path.expand("../../marshall/test/fixtures/tls/localhost.pem", __DIR__),
         keyfile: Path.expand("../../marshall/test/fixtures/tls/localhost.key", __DIR__)}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(server)

    {:ok, client} =
      Client.new(
        "https://127.0.0.1:#{port}",
        "audi_service_" <> String.duplicate("A", 43),
        :gateway,
        host_id: "11234567-89ab-4def-8123-456789abcdef",
        cacertfile: Path.expand("../../marshall/test/fixtures/tls/ca.pem", __DIR__)
      )

    client = Audi.Test.DNSControl.connected(client)

    %{store: store, client: client}
  end

  # @cc [owner:ghuntley,label:verification;protocol] audi-fleet-version-owner-retirement
  # Verified 426 at fetch, acknowledgement or catalog MUST retire even a
  # suspended scheduler, stop later control work and preserve installed expiry.
  test "fleet version refusal retires suspended readiness without reopening polling", c do
    # Exhaustively visit the finite matrix; a random duplicate adds no coverage.
    for stage <- [:fetch, :ack, :catalog, :ready, :catalog_with_job] do
      tasks = start_supervised!({Task.Supervisor, max_children: 20})

      {:ok, listener} =
        :ssl.listen(0, [
          :inet,
          :binary,
          active: false,
          ip: {127, 0, 0, 1},
          certfile: String.to_charlist(Path.join(c.certificate_dir, "leaf.pem")),
          keyfile: String.to_charlist(Path.join(c.certificate_dir, "leaf.key"))
        ])

      {:ok, {_, port}} = :ssl.sockname(listener)
      fixture = spawn_link(fn -> accept_fleet_probes(listener) end)

      worker =
        start_supervised!(
          {Audi.TLS.FleetWorker,
           client: c.client,
           store: c.store,
           tasks: tasks,
           zone: @zone,
           trust_pem: c.roots,
           probe_peer: {{127, 0, 0, 1}, port}}
        )

      try do
        fleet_reply("fleet-certificate", 503, "{}")
        state = :sys.get_state(worker)
        assert not state.halted?
        assert Process.alive?(state.scheduler)
        {:ok, metadata} = Audi.TLS.Store.fleet_metadata(c.store, @host)
        monitor = Process.monitor(state.scheduler)

        body =
          JSON.encode!(%{
            "version" => 1,
            "bundle" => %{
              "host_id" => c.client.host_id,
              "zone" => @zone,
              "generation" => 1,
              "fingerprint" => metadata.fingerprint,
              "expires_at" => DateTime.from_unix!(metadata.expires_at) |> DateTime.to_iso8601(),
              "chain_pem" => c.chain,
              "private_key_pem" => c.key
            }
          })

        if stage == :fetch do
          fleet_reply("fleet-certificate", 426, "invalid version", state.scheduler)
        else
          fleet_reply("fleet-certificate", 200, body)

          if stage == :ack do
            fleet_reply("fleet-certificate-ack", 426, "invalid version", state.scheduler)
          else
            fleet_reply(
              "fleet-certificate-ack",
              200,
              JSON.encode!(%{
                "version" => 1,
                "ack" => %{"host_id" => c.client.host_id, "generation" => 1}
              })
            )

            if stage == :catalog do
              fleet_reply("gateway-catalog", 426, "invalid version", state.scheduler)
            else
              fleet_reply(
                "gateway-catalog",
                200,
                JSON.encode!(%{
                  "version" => 1,
                  "catalog" => %{
                    "service_id" => "22222222-2222-4222-8222-222222222222",
                    "host_id" => c.client.host_id,
                    "service_generation" => 1,
                    "ttl" => 5000,
                    "entries" => [
                      %{
                        "vm_id" => "01234567-89ab-4def-8123-456789abcdef",
                        "placement_id" => "33333333-3333-4333-8333-333333333333",
                        "execution_epoch" => 1,
                        "generation" => 1,
                        "label" => @label
                      }
                    ]
                  }
                })
              )

              if stage == :catalog_with_job do
                assert_receive {:control_request, request_pid, request_ref,
                                "/api/audi/v1/route-ready", _, _},
                               4000

                [job] = Task.Supervisor.children(tasks)
                job_ref = Process.monitor(job)
                :sys.suspend(state.scheduler)
                fleet_reply("gateway-catalog", 426, "invalid version")
                assert_receive {:DOWN, ^job_ref, :process, ^job, :killed}, 1000
                send(request_pid, {request_ref, 503, "{}"})
              else
                fleet_reply("route-ready", 426, "invalid version")
                assert_receive {:DOWN, ^monitor, :process, _, :killed}, 1000
              end
            end
          end
        end

        assert :sys.get_state(worker, 1000).halted?
        if stage != :ready, do: assert_receive({:DOWN, ^monitor, :process, _, :killed}, 1000)
        for _ <- 1..3, do: send(worker, :tick)
        _ = :sys.get_state(worker)
        refute_receive {:control_request, _, _, _, _, _}, 1200
        assert :sys.get_state(worker).last_error == :unsupported_version
        refute Audi.TLS.FleetWorker.automatic_work_enabled?(worker)
        assert {:ok, ^metadata} = Audi.TLS.Store.fleet_metadata(c.store, @host)
        assert Task.Supervisor.children(tasks) == []
      after
        stop_supervised(Audi.TLS.FleetWorker)
        stop_supervised(Task.Supervisor)
        :ssl.close(listener)
        monitor = Process.monitor(fixture)
        assert_receive {:DOWN, ^monitor, :process, ^fixture, _}, 2000
      end
    end
  end

  @spec fleet_reply(binary(), pos_integer(), binary(), pid() | nil) :: reference()
  defp fleet_reply(route, status, body, scheduler \\ nil) do
    path = "/api/audi/v1/" <> route
    assert_receive {:control_request, pid, ref, ^path, _, _}, 7000
    if is_pid(scheduler), do: :sys.suspend(scheduler)
    send(pid, {ref, status, body})
    ref
  end

  @spec accept_fleet_probes(:ssl.sslsocket()) :: :ok
  defp accept_fleet_probes(listener) do
    case :ssl.transport_accept(listener, 1000) do
      {:ok, socket} ->
        case :ssl.handshake(socket, 2000) do
          {:ok, connected} -> :ssl.close(connected)
          {:error, _} -> :ssl.close(socket)
        end

        accept_fleet_probes(listener)

      {:error, :timeout} ->
        accept_fleet_probes(listener)

      {:error, :closed} ->
        :ok
    end
  end

  defp options(c, overrides \\ []) do
    Keyword.merge(
      [
        store: c.store,
        https_port: 443,
        client: c.client,
        connector: {Audi.Test.WebConnector, %{port: 1, owner: self()}},
        zone: @zone,
        browser_origin: @browser_origin
      ],
      overrides
    )
  end

  # Plain-HTTP listener options exclude control configuration, as deployed.
  defp plain_options(c, overrides \\ []) do
    Keyword.merge([store: c.store, https_port: 443, zone: @zone], overrides)
  end

  defp https(host, path, opts \\ []) do
    conn = Plug.Test.conn(Keyword.get(opts, :method, :get), "https://" <> host <> path)
    conn = %{conn | req_headers: conn.req_headers ++ [{"host", host}]}

    conn = if port = Keyword.get(opts, :port), do: %{conn | port: port}, else: conn

    conn =
      if raw_path = Keyword.get(opts, :raw_path),
        do: %{conn | request_path: raw_path},
        else: conn

    conn =
      if Keyword.get(opts, :duplicate_host, false),
        do: %{conn | req_headers: [{"host", host} | conn.req_headers]},
        else: conn

    {adapter, payload} = conn.adapter

    ssl =
      case Keyword.get(opts, :sni, host) do
        nil -> []
        name -> [sni_hostname: String.to_charlist(name)]
      end

    %{conn | adapter: {adapter, Map.put(payload, :ssl_data, ssl)}}
  end

  defp front(conn, options), do: Audi.HTTP.Front.call(conn, Audi.HTTP.Front.init(options))

  defp with_host(conn, host), do: %{conn | req_headers: conn.req_headers ++ [{"host", host}]}

  defp ticket(purpose) do
    prefix =
      Map.fetch!(
        %{
          ticket: "audi_web_login_",
          code: "audi_web_code_",
          cookie: "audi_web_cookie_"
        },
        purpose
      )

    prefix <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)
  end

  defp web_login_request(_c, fields) do
    assert_receive {:control_request, control, ref, "/api/audi/v1/web-login-begin", _, body}, 2000

    send(
      control,
      {ref, 200,
       JSON.encode!(%{
         version: 1,
         login:
           Map.merge(
             %{
               hostname: @host,
               ticket: ticket(:ticket),
               expires_at: DateTime.utc_now() |> DateTime.add(300) |> DateTime.to_iso8601()
             },
             fields
           )
       })}
    )

    body
  end

  defp no_contact do
    refute_received {:control_request, _, _, _, _, _}
    refute_received {:guest_binding, _}
  end

  # @cc [owner:ghuntley,label:verification;recovery] audi-assets-suspended-listener-refusal
  # A healthy actual HTTPS asset listener MUST prove readiness; suspending its
  # nested listener and acceptors MUST refuse the next proof even while the
  # outer supervisor remains alive and immutable files remain available.
  @tag :tmp_dir
  test "asset readiness follows the actual HTTPS service after nested suspension", c do
    relative = "out/vs/workbench/contrib/webview/browser/pre"
    File.mkdir_p!(Path.join(c.tmp_dir, relative))

    for filename <- ["index.html", "fake.html", "service-worker.js"] do
      path = Path.join([c.tmp_dir, relative, filename])
      File.write!(path, filename)
      File.chmod!(path, 0o444)
    end

    descriptor = %{
      protocol: 1,
      commit: String.duplicate("a", 40),
      release: String.duplicate("b", 64)
    }

    windows_descriptor = %{descriptor | release: String.duplicate("d", 64)}

    {:ok, reservation} = :gen_tcp.listen(0, [:inet, ip: {127, 0, 0, 1}])
    {:ok, {_, port}} = :inet.sockname(reservation)
    :ok = :gen_tcp.close(reservation)

    listener =
      start_supervised!(
        {Audi.HTTP.Listener,
         scheme: :https,
         store: c.store,
         zone: @zone,
         ip: {127, 0, 0, 1},
         port: port,
         https_port: port,
         editor_assets: %{
           "linux-x64" => %{root: c.tmp_dir, descriptor: descriptor},
           "win32-x64" => %{root: c.tmp_dir, descriptor: windows_descriptor}
         }}
      )

    peer = {{127, 0, 0, 1}, port}
    assert :ok = Audi.HTTP.EditorAssetsProbe.check(peer, @zone, c.roots, descriptor)
    assert :ok = Audi.HTTP.EditorAssetsProbe.check(peer, @zone, c.roots, windows_descriptor)

    wrong_release = %{descriptor | release: String.duplicate("c", 64)}

    assert {:error, :editor_assets_not_ready} =
             Audi.HTTP.EditorAssetsProbe.check(peer, @zone, c.roots, wrong_release)

    assert {:error, :editor_assets_not_ready} =
             Audi.HTTP.EditorAssetsProbe.check(peer, "other.example", c.roots, descriptor)

    assert :ok = ThousandIsland.suspend(listener)
    assert Process.alive?(listener)

    assert {:error, :editor_assets_not_ready} =
             Audi.HTTP.EditorAssetsProbe.check(peer, @zone, c.roots, descriptor)

    assert {:error, :editor_assets_not_ready} =
             Audi.HTTP.EditorAssetsProbe.check(peer, @zone, c.roots, windows_descriptor)

    assert Process.alive?(listener)
    assert File.regular?(Path.join([c.tmp_dir, relative, "index.html"]))
  end

  # @cc [owner:ghuntley,label:verification;security] audi-front-plain-upgrade
  # Plain HTTP MUST redirect permanently to the same host/path/query on the
  # configured HTTPS port without control or guest contact, and MUST refuse
  # plain HTTP for hosts outside the installed wildcard.
  test "plain HTTP permanently upgrades exactly once", c do
    conn =
      front(
        Plug.Test.conn(:get, "http://#{@host}/deep/path?x=1") |> with_host(@host),
        plain_options(c)
      )

    assert conn.status == 308
    assert get_resp_header(conn, "location") == ["https://#{@host}/deep/path?x=1"]
    assert get_resp_header(conn, "cache-control") == ["no-store"]
    assert get_resp_header(conn, "connection") == ["close"]
    no_contact()

    conn =
      front(
        Plug.Test.conn(:get, "http://#{@host}/") |> with_host(@host),
        plain_options(c, https_port: 8443)
      )

    assert conn.status == 308
    assert get_resp_header(conn, "location") == ["https://#{@host}:8443/"]

    conn =
      front(
        Plug.Test.conn(:get, "http://outside.example/") |> with_host("outside.example"),
        plain_options(c)
      )

    assert conn.status == 421
    assert conn.resp_body == "Misdirected request\n"
    no_contact()
  end

  # @cc [owner:ghuntley,label:verification;security] audi-front-misdirected-refusal
  # HTTPS requests MUST be refused without control or guest contact unless the
  # connection SNI exactly equals a single wildcard Host on the configured port,
  # with an absolute request path.
  test "misdirected HTTPS requests refuse before any admission", c do
    for {name, conn} <- [
          {"no SNI", https(@host, "/", sni: nil)},
          {"SNI mismatch",
           https(@host, "/", sni: "other-0123456789ab4def8123456789abcdef." <> @zone)},
          {"unexpected port", https(@host, "/", port: 8443)},
          {"duplicate Host", https(@host, "/", duplicate_host: true)},
          {"relative path", https(@host, "/", raw_path: "relative")},
          {"unknown zone", https("demo-0123456789ab4def8123456789abcdef.other.example", "/")}
        ] do
      response = front(conn, options(c))
      assert response.status == 421, name
      assert response.resp_body == "Misdirected request\n", name
    end

    no_contact()
  end

  # @cc [owner:ghuntley,label:verification;security] audi-front-callback-gating
  # The reserved /_audi/ namespace MUST NOT reach guests. The callback MUST
  # require a GET with exactly its ticket/code query and one state cookie before
  # any control redemption; other reserved paths return 404. The bare prefix
  # without trailing slash remains ordinary guest content.
  test "reserved callback gating and namespace boundary", c do
    for {name, conn} <- [
          {"callback without state", https(@host, "/_audi/callback?ticket=a&code=b")},
          {"callback POST", https(@host, "/_audi/callback?ticket=a&code=b", method: :post)},
          {"callback missing code", https(@host, "/_audi/callback?ticket=a")},
          {"callback extra parameter", https(@host, "/_audi/callback?ticket=a&code=b&x=1")},
          {"other reserved path", https(@host, "/_audi/other")},
          {"double slash", https(@host, "/_audi//callback")}
        ] do
      response = front(conn, options(c))

      assert response.status in [403, 404], name
      refute_received {:control_request, _, _, _, _, _}
    end

    # Without a configured control client the callback has no redemption path
    # and remains reserved.
    response = front(https(@host, "/_audi/callback?ticket=a&code=b"), options(c, client: nil))
    assert response.status == 404
    no_contact()

    # The exact prefix without slash is outside the reserved namespace and
    # reaches ordinary admission like any other guest path.
    task = Task.async(fn -> front(https(@host, "/_audi"), options(c)) end)

    assert_receive {:control_request, control, ref, "/api/audi/v1/web-open", _,
                    %{"app_port" => 0}},
                   2000

    send(control, {ref, 401, JSON.encode!(%{error: "authentication_required"})})
    begun = web_login_request(c, %{})
    assert Task.await(task, 4000).status == 303
    assert begun["label"] == @label
  end

  test "a complete callback redeems state and pins host-only cookies", c do
    return = Base.url_encode64("/back?here=1", padding: false)
    cookie_value = ticket(:cookie)

    task =
      Task.async(fn ->
        https(@host, "/_audi/callback?ticket=#{ticket(:ticket)}&code=#{ticket(:code)}")
        |> put_req_header(
          "cookie",
          "__Host-audi_state=#{Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)}; __Host-audi_return=#{return}"
        )
        |> front(options(c))
      end)

    assert_receive {:control_request, control, ref, "/api/audi/v1/web-login-exchange", _,
                    _request},
                   2000

    send(
      control,
      {ref, 200,
       JSON.encode!(%{
         version: 1,
         login: %{
           hostname: @host,
           cookie: cookie_value,
           expires_at: DateTime.utc_now() |> DateTime.add(43_200) |> DateTime.to_iso8601()
         }
       })}
    )

    response = Task.await(task, 4000)
    assert response.status == 303
    assert get_resp_header(response, "location") == ["/back?here=1"]
    state = response.resp_cookies["__Host-audi_state"]
    return_cookie = response.resp_cookies["__Host-audi_return"]
    session = response.resp_cookies["__Host-audi_session"]
    assert session.value == cookie_value
    assert session.http_only and session.secure
    assert session.path == "/" and session.same_site == "Lax"
    assert session.max_age in 1..43_200
    assert state.max_age == 0 and return_cookie.max_age == 0
    refute_received {:guest_binding, _}
  end

  # @cc [owner:ghuntley,label:verification;security] audi-front-refusal-classes
  # Admission failure MUST map onto closed classes without guest contact:
  # missing identity starts exactly one browser redirect, denied membership
  # returns 403, missing route/execution control authority returns 503, and a
  # gateway without control configuration returns 503.
  test "admission refusal classes keep guests untouched", c do
    responses = [
      anonymous: {401, %{error: "authentication_required"}},
      identified_denied: {401, %{error: "unauthorized"}},
      membership_denied: {403, %{error: "unauthorized"}},
      capacity: {429, %{error: "capacity"}},
      unavailable: {503, %{error: "temporarily_unavailable"}}
    ]

    expect = %{
      anonymous: 303,
      identified_denied: 503,
      membership_denied: 403,
      capacity: 503,
      unavailable: 503
    }

    for {name, {status, body}} <- responses do
      task = Task.async(fn -> front(https(@host, "/after/withdrawal"), options(c)) end)

      assert_receive {:control_request, control, ref, "/api/audi/v1/web-open", _, request}, 2000
      assert request["label"] == @label
      send(control, {ref, status, JSON.encode!(body)})

      if expect[name] == 303 do
        begun = web_login_request(c, %{})
        assert begun["label"] == @label
      end

      response = Task.await(task, 4000)
      assert response.status == expect[name], "#{name} returned #{response.status}"
      refute_received {:guest_binding, _}

      if expect[name] == 303 do
        [location] = get_resp_header(response, "location")
        assert String.starts_with?(location, @browser_origin <> "/audi/authorize/")
        refute String.contains?(location, c.client.origin)

        state = response.resp_cookies["__Host-audi_state"]
        assert state.path == "/" and state.http_only and state.secure
        assert state.same_site == "Lax" and state.max_age == 300
      else
        assert response.resp_body in ["Access denied\n", "Service unavailable\n"]
        assert response.resp_cookies == %{}
        no_control_after_open()
      end
    end
  end

  test "a gateway without control configuration refuses application traffic", c do
    for overrides <- [
          [client: nil, connector: nil, zone: nil],
          [client: nil]
        ] do
      response = front(https(@host, "/"), options(c, overrides))
      assert response.status == 503
      assert response.resp_body == "Service unavailable\n"
    end

    no_contact()
  end

  defp no_control_after_open do
    refute_received {:control_request, _, _, _, _, _}
  end
end
