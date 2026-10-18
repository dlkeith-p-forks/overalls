defmodule Galileo.GitHub.HTTPTest do
  use ExUnit.Case, async: false
  import Kernel, except: [binding: 0]
  import Hegel
  import Hegel.Gen
  import Plug.Conn
  alias Galileo.GitHub.Capabilities
  alias OverallsProtocol.GitHub

  @host "01234567-89ab-4def-8123-456789abcdef"
  @vm "11234567-89ab-4def-8123-456789abcdef"
  @placement "21234567-89ab-4def-8123-456789abcdef"
  @connection "31234567-89ab-4def-8123-456789abcdef"
  @lease "41234567-89ab-4def-8123-456789abcdef"
  @fixtures Path.expand("../../marshall/test/fixtures/tls", __DIR__)
  @moduletag capture_log: true

  setup context do
    if Map.get(context, :hegel, false), do: %{}, else: fixtures()
  end

  # @cc [owner:ghuntley,label:verification;security] github-before-effect-refusals
  # Refusal, malformed authority and control loss MUST read no upload, open no
  # upstream attempt and preserve counters; only verified refusal returns403.
  property "refused or unavailable control cannot read a body or open an origin", context do
    context = Map.merge(context, fixtures())

    refusal =
      draw(
        "refusal",
        member_of([
          {:error, "unauthorized"},
          {:error, "unavailable"},
          {:ok, %{"target" => "https://attacker.invalid"}}
        ])
      )

    control = Galileo.ControlStub.start(fn _op, _body -> refusal end)
    baseline = :counters.get(Galileo.Counter.counters(), 1)
    owner = self()
    conn = request("POST", "/api/graphql", "unread")
    {_, payload} = conn.adapter
    conn = %{conn | adapter: {Galileo.GitHubRaisingBodyAdapter, payload}}

    response =
      Galileo.HTTP.call(
        conn,
        config(control, context.capabilities, fn _, _ -> send(owner, :unexpected_origin) end)
      )

    assert response.status == if(refusal == {:error, "unauthorized"}, do: 403, else: 503)
    assert :counters.get(Galileo.Counter.counters(), 1) == baseline
    refute_receive :unexpected_origin, 0
  end

  test "authority response latency consumes admission before any effect", context do
    control =
      Galileo.ControlStub.start(fn
        "galileo.github.authorize", _ ->
          Process.sleep(550)

          {:ok,
           %{
             "target" => "https://api.github.com",
             "strip_prefix" => nil,
             "headers" => [["authorization", "Bearer synthetic-owner"]],
             "ttl" => 500,
             "lease" => GitHub.encode_lease(lease())
           }}
      end)

    owner = self()
    conn = request("POST", "/api/graphql", "unread")
    {_, payload} = conn.adapter
    conn = %{conn | adapter: {Galileo.GitHubRaisingBodyAdapter, payload}}

    response =
      Galileo.HTTP.call(
        conn,
        config(control, context.capabilities, fn _, _ -> send(owner, :unexpected_origin) end)
      )

    assert response.status == 503
    refute_receive :unexpected_origin, 0
  end

  test "REST and GraphQL inject owner authority and preserve safe CLI metadata", context do
    control = control()
    owner = self()

    stream = fn authorization, options ->
      send(owner, {:upstream, authorization, Keyword.fetch!(options, :headers)})

      assert {:ok, "query", _} =
               Keyword.fetch!(options, :pull).(Keyword.fetch!(options, :body_state))

      emit(
        options,
        200,
        [
          {"content-type", "application/json"},
          {"set-cookie", "secret"},
          {"x-ratelimit-remaining", "21"}
        ],
        ~s({"viewer":{"login":"fixture"}})
      )
    end

    conn =
      request("POST", "/api/graphql", "query")
      |> put_req_header("authorization", "Bearer guest")
      |> put_req_header("cookie", "guest=secret")
      |> put_req_header("x-github-api-version", "2022-11-28")

    result = Galileo.HTTP.call(conn, config(control, context.capabilities, stream))
    assert result.status == 200
    assert Jason.decode!(result.resp_body) == %{"viewer" => %{"login" => "fixture"}}
    assert get_resp_header(result, "set-cookie") == []
    assert get_resp_header(result, "x-ratelimit-remaining") == ["21"]

    assert_receive {:upstream,
                    %{
                      target: "https://api.github.com",
                      headers: [{"authorization", "Bearer synthetic-owner"}]
                    }, headers}

    refute List.keymember?(headers, "authorization", 0)
    refute List.keymember?(headers, "cookie", 0)
    assert {"x-github-api-version", "2022-11-28"} in headers
    assert_receive {:closed, %{"id" => @lease}}
  end

  test "read redirects renew the same lease and signed storage receives no OAuth token",
       context do
    owner = self()
    control = control()

    stream = fn authorization, options ->
      send(
        owner,
        {:attempt, authorization.target, authorization.headers, Keyword.fetch!(options, :query)}
      )

      case authorization.target do
        "https://api.github.com" ->
          assert {:ok, "initial", _} =
                   Keyword.fetch!(options, :pull).(Keyword.fetch!(options, :body_state))

          emit(
            options,
            302,
            [
              {"location",
               "https://release-assets.githubusercontent.com/object?sig=synthetic-storage"}
            ],
            ""
          )

        "https://release-assets.githubusercontent.com" ->
          assert {:ok, "", _} =
                   Keyword.fetch!(options, :pull).(Keyword.fetch!(options, :body_state))

          emit(options, 200, [{"content-type", "application/zip"}], "archive")
      end
    end

    result =
      Galileo.HTTP.call(
        request("GET", "/api/repos/o/r/actions/artifacts/1/zip", "initial"),
        config(control, context.capabilities, stream)
      )

    assert result.status == 200

    assert_receive {:attempt, "https://api.github.com",
                    [{"authorization", "Bearer synthetic-owner"}], ""}

    assert_receive {:attempt, "https://release-assets.githubusercontent.com", [],
                    "?sig=synthetic-storage"}

    assert_receive {:renewed, %{"id" => @lease}}
    assert_receive {:closed, %{"id" => @lease}}
    refute result.resp_body =~ "synthetic-storage"
  end

  property "mutating responses never follow redirects or retry", context do
    context = Map.merge(context, fixtures())
    method = draw("method", member_of(~w(POST PUT PATCH DELETE)))
    status = draw("status", member_of([301, 302, 303, 307, 308]))
    control = control()
    owner = self()
    nonce = make_ref()

    stream = fn _authorization, options ->
      send(owner, {:mutation_attempt, nonce})
      emit(options, status, [{"location", "https://api.github.com/repos/redirected"}], "")
    end

    result =
      Galileo.HTTP.call(
        request(method, "/api/repos/o/r", "payload"),
        config(control, context.capabilities, stream)
      )

    assert result.status == 502
    assert_receive {:mutation_attempt, ^nonce}
    refute_receive {:mutation_attempt, ^nonce}, 0
  end

  test "exception records failure, closes the pin and cleans process state exactly once",
       context do
    control = control()
    baseline = :counters.get(Galileo.Counter.counters(), 1)
    slo = Galileo.SLO.snapshot()
    stream = fn _, _ -> raise "synthetic transport failure" end

    result =
      Galileo.HTTP.call(
        request("POST", "/api/graphql", "body"),
        config(control, context.capabilities, stream)
      )

    assert result.status == 503
    assert :counters.get(Galileo.Counter.counters(), 1) == baseline
    assert Galileo.SLO.snapshot().requests == slo.requests + 1
    assert Galileo.SLO.snapshot().failures == slo.failures + 1
    assert Process.get({Galileo.GitHub.HTTP, :response}) == nil
    assert Process.get({Galileo.GitHub.HTTP, :upload}) == nil
    assert Process.get({Galileo.GitHub.HTTP, :success}) == nil
    assert_receive {:closed, %{"id" => @lease}}
  end

  test "LFS uploads enforce provider action headers, content size, digest and one use", context do
    control = control()
    owner = self()

    for {body, expected} <- [{"abc", 200}, {"bad", 502}, {"long", 502}, {"ab", 502}] do
      oid = :crypto.hash(:sha256, "abc") |> Base.encode16(case: :lower)

      transfer = %{
        url: "https://github-cloud.s3.amazonaws.com/object?sig=synthetic",
        headers: [{"authorization", "RemoteAuth synthetic-lfs"}],
        method: "PUT",
        object: %{oid: oid, size: 3, repository: "/o/r.git/info/lfs"},
        ttl: 60_000
      }

      assert {:ok, path} =
               Capabilities.mint_transfer(transfer, binding(), lease(), context.capabilities)

      stream = fn authorization, options ->
        send(owner, :lfs_attempt)
        assert authorization.target == "https://github-cloud.s3.amazonaws.com"

        assert authorization.headers == [
                 {"content-length", "3"},
                 {"authorization", "RemoteAuth synthetic-lfs"}
               ]

        case Keyword.fetch!(options, :pull).(Keyword.fetch!(options, :body_state)) do
          {:ok, "abc", _} -> emit(options, 200, [], "")
          {:error, :invalid_body} -> %{outcome: :source_error, status: nil}
        end
      end

      config = config(control, context.capabilities, stream)
      assert Galileo.HTTP.call(request("PUT", path, body), config).status == expected
      assert_receive :lfs_attempt
      assert Galileo.HTTP.call(request("PUT", path, body), config).status == 403
      refute_receive :lfs_attempt, 0
    end
  end

  test "the exact-size final upload chunk is withheld until frontend EOF", context do
    body = String.duplicate("a", 65_536)

    transfer = %{
      url: "https://github-cloud.s3.amazonaws.com/object?sig=synthetic",
      headers: [],
      method: "PUT",
      object: %{
        oid: Base.encode16(:crypto.hash(:sha256, body), case: :lower),
        size: byte_size(body),
        repository: "/o/r.git/info/lfs"
      },
      ttl: 60_000
    }

    assert {:ok, path} =
             Capabilities.mint_transfer(transfer, binding(), lease(), context.capabilities)

    stream = fn _authorization, options ->
      # A successful :more carrying the whole content-length would allow an
      # upstream server to commit before the trailing body is inspected.
      assert {:error, :invalid_body} =
               Keyword.fetch!(options, :pull).(Keyword.fetch!(options, :body_state))

      %{outcome: :source_error, status: nil}
    end

    assert Galileo.HTTP.call(
             request("PUT", path, body <> "trailing"),
             config(control(), context.capabilities, stream)
           ).status == 502
  end

  test "LFS verify bodies name only the exact capability object", context do
    oid = String.duplicate("a", 64)
    valid = Jason.encode!(%{"oid" => oid, "size" => 3})

    for {body, expected} <- [
          {valid, 200},
          {Jason.encode!(%{"oid" => String.duplicate("b", 64), "size" => 3}), 502},
          {Jason.encode!(%{"oid" => oid, "size" => 4}), 502},
          {Jason.encode!(%{"oid" => oid, "size" => 3, "extra" => true}), 502},
          {"{\"oid\":\"" <> oid <> "\",\"size\":3,\"oid\":\"" <> oid <> "\"}", 502},
          {valid <> String.duplicate(" ", 4096), 502},
          {"invalid", 502}
        ] do
      transfer = %{
        url: "https://github.com/o/r.git/info/lfs/verify",
        headers: [{"authorization", "RemoteAuth synthetic-verify"}],
        method: "POST",
        object: %{oid: oid, size: 3, repository: "/o/r.git/info/lfs"},
        ttl: 60_000
      }

      assert {:ok, path} =
               Capabilities.mint_transfer(transfer, binding(), lease(), context.capabilities)

      stream = fn authorization, options ->
        assert authorization.headers == [{"authorization", "RemoteAuth synthetic-verify"}]

        case Keyword.fetch!(options, :pull).(Keyword.fetch!(options, :body_state)) do
          {:ok, ^valid, _} -> emit(options, 200, [], "")
          {:error, :invalid_body} -> %{outcome: :source_error, status: nil}
        end
      end

      assert Galileo.HTTP.call(
               request("POST", path, body),
               config(control(), context.capabilities, stream)
             ).status == expected
    end
  end

  test "real verified TLS origin observes one injected mutation and sanitized response",
       context do
    responder = fn conn ->
      {:ok, "mutation", conn} = read_body(conn)

      conn
      |> put_resp_header("content-type", "application/json")
      |> put_resp_header("set-cookie", "provider-secret")
      |> send_resp(
        200,
        Jason.encode!(%{
          "archive" => "https://release-assets.githubusercontent.com/object?sig=synthetic"
        })
      )
    end

    origin =
      start_supervised!(
        {Bandit,
         plug: {Galileo.GitHubOrigin, {self(), responder}},
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         certfile: Path.join(@fixtures, "localhost.pem"),
         keyfile: Path.join(@fixtures, "localhost.key")}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(origin)

    stream = fn authorization, options ->
      assert authorization.target == "https://api.github.com"

      Galileo.Upstream.stream(
        %{authorization | target: "https://localhost:#{port}"},
        Keyword.put(options, :transport_opts, cacertfile: Path.join(@fixtures, "ca.pem"))
      )
    end

    result =
      Galileo.HTTP.call(
        request("POST", "/api/repos/o/r", "mutation"),
        config(control(), context.capabilities, stream)
      )

    assert result.status == 200
    assert result.resp_body =~ "/capabilities/"
    refute result.resp_body =~ "sig="
    assert get_resp_header(result, "set-cookie") == []
    assert_receive {:origin_request, "POST", "/repos/o/r", headers}
    assert {"authorization", "Bearer synthetic-owner"} in headers
    refute_receive {:origin_request, _, _, _}, 0
  end

  @spec emit(keyword(), pos_integer(), [{String.t(), String.t()}], binary()) :: map()
  defp emit(options, status, headers, body) do
    consume = Keyword.fetch!(options, :consume)
    :ok = consume.({:status, status})
    :ok = consume.({:headers, headers})
    if body != "", do: :ok = consume.({:data, body})
    %{outcome: :completed, status: status}
  end

  @spec control() :: Galileo.Control.t()
  defp control do
    owner = self()

    Galileo.ControlStub.start(fn
      "galileo.github.authorize", _ ->
        {:ok,
         %{
           "target" => "https://api.github.com",
           "strip_prefix" => nil,
           "headers" => [["authorization", "Bearer synthetic-owner"]],
           "ttl" => 2000,
           "lease" => GitHub.encode_lease(lease())
         }}

      "galileo.github.renew", %{"lease" => lease} ->
        send(owner, {:renewed, lease})
        {:ok, %{"version" => 1, "ttl" => 2000}}

      "galileo.github.close", %{"lease" => lease} ->
        send(owner, {:closed, lease})
        {:ok, %{"closed" => true}}
    end)
  end

  @spec config(Galileo.Control.t(), pid(), (map(), keyword() -> map())) :: map()
  defp config(control, capabilities, stream),
    do: %{
      host_id: @host,
      control: control,
      capabilities: capabilities,
      github_upstream_stream: stream,
      cancel_frontend: fn -> :ok end
    }

  @spec request(String.t(), String.t(), binary()) :: Plug.Conn.t()
  defp request(method, path, body) do
    encoded = binding() |> Jason.encode!() |> Base.url_encode64(padding: false)
    conn = Plug.Test.conn(method, path, body) |> put_req_header("x-overalls-binding", encoded)

    %{
      conn
      | host: GitHub.hostname(),
        req_headers: [{"host", GitHub.hostname()} | conn.req_headers]
    }
  end

  @spec fixtures() :: %{capabilities: pid()}
  defp fixtures do
    Overalls.HegelFixtures.start_fixture!({Galileo.SLO, []})
    %{capabilities: Overalls.HegelFixtures.start_fixture!({Capabilities, name: nil})}
  end

  @spec binding() :: map()
  defp binding,
    do: %{
      "host_id" => @host,
      "vm_id" => @vm,
      "placement_id" => @placement,
      "execution_epoch" => 1
    }

  @spec lease() :: GitHub.lease()
  defp lease, do: %{id: @lease, connection_id: @connection, generation: 2}
end
