defmodule Galileo.HTTPTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  import Plug.Conn

  @host_id "01234567-89ab-4def-8123-456789abcdef"

  # @cc [owner:ghuntley,label:verification;security] galileo-guest-refusal-before-effects
  # Across verified control refusal bodies, HTTP403 MUST reach the guest as
  # HTTP403; invalid/outage statuses MUST remain HTTP503. No refused request
  # may read its upload, invoke an upstream callback or change active counters.
  property "verified authority refusals preserve guest status without upstream effects" do
    check all(
            refusal <-
              member_of([{:error, "unauthorized"}, {:error, "invalid_request"}, {:refuse, 503}]),
            max_runs: 6
          ) do
      control =
        case refusal do
          {:refuse, status} -> Galileo.ControlStub.start({:refuse, status})
          error -> Galileo.ControlStub.start(fn _op, _body -> error end)
        end

      owner = self()
      baseline = :counters.get(Galileo.Counter.counters(), 1)

      conn =
        Plug.Test.conn("POST", "/upload", "unread")
        |> put_req_header("x-overalls-binding", binding_header())
        |> raising_body_adapter()
        |> Map.put(:host, "fixture.integration.internal")

      conn = %{conn | req_headers: [{"host", "fixture.integration.internal"} | conn.req_headers]}

      result =
        Galileo.HTTP.call(conn, %{
          host_id: @host_id,
          control: control,
          upstream_stream: fn _, _ -> send(owner, :unexpected_upstream) end
        })

      unauthorized? = refusal == {:error, "unauthorized"}
      assert result.status == if(unauthorized?, do: 403, else: 503)
      assert :counters.get(Galileo.Counter.counters(), 1) == baseline
      refute_receive :unexpected_upstream, 10

      if unauthorized? do
        assert {:error, :unauthorized} = Galileo.Control.request(control, "renew", %{})
      end
    end
  end

  defmodule RaisingBodyAdapter do
    @behaviour Plug.Conn.Adapter
    alias Plug.Adapters.Test.Conn, as: TestAdapter

    @impl true
    defdelegate send_resp(payload, status, headers, body), to: TestAdapter

    @impl true
    defdelegate send_file(payload, status, headers, path, offset, length), to: TestAdapter

    @impl true
    defdelegate send_chunked(payload, status, headers), to: TestAdapter

    @impl true
    defdelegate chunk(payload, body), to: TestAdapter

    @impl true
    defdelegate inform(payload, status, headers), to: TestAdapter

    @impl true
    defdelegate upgrade(payload, protocol, options), to: TestAdapter

    @impl true
    defdelegate push(payload, path, headers), to: TestAdapter

    @impl true
    defdelegate get_peer_data(payload), to: TestAdapter

    @impl true
    defdelegate get_sock_data(payload), to: TestAdapter

    @impl true
    defdelegate get_ssl_data(payload), to: TestAdapter

    @impl true
    defdelegate get_http_protocol(payload), to: TestAdapter

    @impl true
    def read_req_body(_payload, _options), do: raise("stalled request body")
  end

  test "body pull exception cleans active request state without retry" do
    start_supervised!({Galileo.SLO, []})
    test = self()

    control =
      Galileo.ControlStub.start(fn "galileo.authorize", _body ->
        send(test, :authorized)

        {:ok,
         %{
           "target" => "https://api.example.test",
           "strip_prefix" => nil,
           "headers" => [],
           "ttl" => 5000
         }}
      end)

    baseline = :counters.get(Galileo.Counter.counters(), 1)
    slo_before = Galileo.SLO.snapshot()
    binding = binding_header()
    owner = self()

    upstream_stream = fn _authorization, options ->
      send(owner, :origin_attempt)
      pull = Keyword.fetch!(options, :pull)
      pull.(Keyword.fetch!(options, :body_state))
    end

    conn =
      Plug.Test.conn("POST", "/upload", "unread")
      |> put_req_header("x-overalls-binding", binding)
      |> raising_body_adapter()

    conn = %{conn | req_headers: [{"host", "example.integration.internal"} | conn.req_headers]}

    Process.put({Galileo.HTTP, :conn}, :stale)

    response =
      Galileo.HTTP.call(conn, %{
        host_id: @host_id,
        control: control,
        upstream_stream: upstream_stream,
        cancel_frontend: fn -> :ok end
      })

    assert response.status == 503
    assert Jason.decode!(response.resp_body) == %{"error" => "unavailable"}
    assert_receive :authorized
    assert_receive :origin_attempt
    refute_receive :origin_attempt, 100
    assert :counters.get(Galileo.Counter.counters(), 1) == baseline
    slo_after = Galileo.SLO.snapshot()
    assert slo_after.requests == slo_before.requests + 1
    assert slo_after.failures == slo_before.failures + 1
    assert Process.get({Galileo.HTTP, :conn}) == nil
  end

  defp binding_header do
    %{
      "host_id" => @host_id,
      "vm_id" => "11234567-89ab-4def-8123-456789abcdef",
      "placement_id" => "21234567-89ab-4def-8123-456789abcdef",
      "execution_epoch" => 1
    }
    |> Jason.encode!()
    |> Base.url_encode64(padding: false)
  end

  defp raising_body_adapter(%{adapter: {_adapter, payload}} = conn),
    do: %{conn | adapter: {RaisingBodyAdapter, payload}}
end
