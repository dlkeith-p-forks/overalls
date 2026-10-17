defmodule MarshallWeb.ControlAPITest do
  use MarshallWeb.ConnCase, async: false
  use ExUnitProperties

  alias OverallsProtocol.Control.{Close, Envelope}
  alias Marshall.Control.Socket
  alias Marshall.Galileo
  alias Marshall.Galileo.Credentials

  setup do
    fixture = Marshall.TerminalFixtures.terminal_fixture(%{profile: :standard})
    {:ok, key} = Credentials.rotate(fixture.vm.host_id, 3600)

    binding = %{
      "host_id" => fixture.vm.host_id,
      "vm_id" => fixture.vm.id,
      "placement_id" => fixture.vm.current_placement_id,
      "execution_epoch" => fixture.vm.execution_epoch
    }

    Map.merge(fixture, %{token: key.id <> "." <> key.secret, binding: binding})
  end

  @spec upgrade(map()) :: Plug.Conn.t()
  defp upgrade(headers) do
    conn =
      Enum.reduce(headers, Phoenix.ConnTest.build_conn(:get, "/api/control/v1"), fn {k, v},
                                                                                    conn ->
        Plug.Conn.put_req_header(conn, k, v)
      end)

    # Plug forbids put_req_header("host"); WebSockAdapter requires the header.
    conn = %{
      conn
      | scheme: :https,
        req_headers: [{"host", "control.example.test"} | conn.req_headers]
    }

    MarshallWeb.ControlAPI.call(conn, [])
  end

  test "the upgrade refuses wrong versions, services and credentials before any socket",
       context do
    good = %{
      "overalls-control" => "1",
      "overalls-service" => "galileo",
      "authorization" => "Bearer " <> context.token
    }

    assert upgrade(Map.delete(good, "overalls-control")).status == 426
    assert upgrade(%{good | "overalls-control" => "2"}).status == 426
    assert upgrade(%{good | "overalls-service" => "unknown"}).status == 401

    assert upgrade(%{good | "authorization" => "Bearer " <> String.duplicate("x", 80)}).status ==
             401

    assert upgrade(Map.delete(good, "authorization")).status == 401

    plain = MarshallWeb.ControlAPI.call(Phoenix.ConnTest.build_conn(:get, "/api/control/v1"), [])
    assert plain.status == 404

    upgraded =
      upgrade(
        Map.merge(good, %{
          "connection" => "Upgrade",
          "upgrade" => "websocket",
          "sec-websocket-key" => OverallsProtocol.WebSocket.Handshake.key(),
          "sec-websocket-version" => "13"
        })
      )

    assert upgraded.state == :upgraded
  end

  @spec socket(map()) :: map()
  defp socket(context) do
    {:ok, principal} = Marshall.Control.Services.Galileo.authenticate(context.token)

    {:ok, state} =
      Socket.init(%{
        service: "galileo",
        module: Marshall.Control.Services.Galileo,
        principal: principal
      })

    state
  end

  @spec hello(map(), map()) :: WebSock.handle_result()
  defp hello(state, bind \\ %{}),
    do:
      Socket.handle_in(
        {Envelope.encode({:hello, %{service: "galileo", bind: bind}}), [opcode: :text]},
        state
      )

  @spec closed?(WebSock.handle_result(), OverallsProtocol.Control.Close.reason()) :: boolean()
  defp closed?({:stop, :normal, {code, ""}, _state}, reason), do: code == Close.code(reason)
  defp closed?(_result, _reason), do: false

  test "hello must come first, for the upgraded service, with the current version", context do
    state = socket(context)
    request = Envelope.encode({:req, %{id: 1, op: "galileo.identity", body: %{}}})
    assert closed?(Socket.handle_in({request, [opcode: :text]}, state), :protocol_violation)

    other = Envelope.encode({:hello, %{service: "ziggy", bind: %{}}})
    assert closed?(Socket.handle_in({other, [opcode: :text]}, state), :refused)

    v2 = JSON.encode!(%{"k" => "hello", "v" => 2, "service" => "galileo", "bind" => %{}})
    assert closed?(Socket.handle_in({v2, [opcode: :text]}, state), :unsupported_version)
    assert closed?(hello(state, %{"x" => 1}), :refused)
    assert closed?(Socket.handle_in({"x", [opcode: :binary]}, state), :protocol_violation)
  end

  # @cc [owner:ghuntley,label:verification;protocol] control-first-frame-refuses-unbound-messages
  # Every valid non-hello envelope, including heartbeat messages, MUST close an
  # unbound upgraded socket with protocol_violation without identity or tasks.
  # The same heartbeat counters MUST work after a valid identity-binding hello.
  property "every non-hello first envelope is refused before identity binding", context do
    check all(drawn <- integer(0..9_007_199_254_740_991), max_runs: 10) do
      for counter <- [0, 1, 9_007_199_254_740_991, drawn] do
        messages = [
          {:ping, counter},
          {:pong, counter},
          :resync,
          {:req, %{id: counter, op: "galileo.identity", body: %{}}},
          {:res, %{id: counter, result: {:ok, %{}}}},
          {:res, %{id: counter, result: {:error, "unavailable"}}},
          {:hint, %{kind: "user", id: context.owner.id}},
          {:welcome, %{conn: "fixture", heartbeat_ms: 5_000, limits: %{}}}
        ]

        for message <- messages do
          state = socket(context)
          text = Envelope.encode(message)
          assert {:ok, _decoded} = Envelope.decode(text)

          case Socket.handle_in({text, [opcode: :text]}, state) do
            {:stop, :normal, {4005, ""}, refused} ->
              identity_absent = is_nil(refused.identity)
              tasks_empty = refused.tasks == %{}
              principal_unchanged = refused.principal == state.principal
              assert identity_absent
              assert tasks_empty
              assert principal_unchanged

            result ->
              kind =
                case message do
                  {kind, _fields} -> kind
                  :resync -> :resync
                end

              flunk(
                "non-hello first envelope was not refused: kind=#{kind}, result=#{result_tag(result)}"
              )
          end
        end

        {welcome, bound} =
          case hello(socket(context)) do
            {:push, {:text, welcome}, bound} -> {welcome, bound}
            result -> flunk("valid hello control failed: result=#{result_tag(result)}")
          end

        assert {:ok, {:welcome, _}} = Envelope.decode(welcome)
        identity_bound = not is_nil(bound.identity)
        assert identity_bound

        case Socket.handle_in({Envelope.encode({:ping, counter}), [opcode: :text]}, bound) do
          {:push, {:text, pong}, ping_state} ->
            assert {:ok, {:pong, ^counter}} = Envelope.decode(pong)
            identity_unchanged = ping_state.identity == bound.identity
            tasks_empty = ping_state.tasks == %{}
            assert identity_unchanged
            assert tasks_empty

          result ->
            flunk("bound ping control failed: result=#{result_tag(result)}")
        end

        case Socket.handle_in({Envelope.encode({:pong, counter}), [opcode: :text]}, bound) do
          {:ok, pong_state} ->
            identity_unchanged = pong_state.identity == bound.identity
            tasks_empty = pong_state.tasks == %{}
            assert identity_unchanged
            assert tasks_empty

          result ->
            flunk("bound pong control failed: result=#{result_tag(result)}")
        end
      end
    end
  end

  # @cc [owner:ghuntley,label:verification;security] control-property-closed-result-diagnostics
  # Failure witnesses MUST expose only a closed callback tag, never principal,
  # credential, request body or frame contents from the callback result.
  @spec result_tag(WebSock.handle_result()) :: :push | :ok | :stop
  defp result_tag({:push, _frame, _state}), do: :push
  defp result_tag({:ok, _state}), do: :ok
  defp result_tag({:stop, _reason, _frame, _state}), do: :stop

  test "a bound socket answers requests through the domain and correlates by id", context do
    {:push, {:text, welcome}, state} = hello(socket(context))
    assert {:ok, {:welcome, %{heartbeat_ms: 5_000}}} = Envelope.decode(welcome)

    request = Envelope.encode({:req, %{id: 7, op: "galileo.identity", body: %{}}})
    assert {:ok, state} = Socket.handle_in({request, [opcode: :text]}, state)
    assert_receive {ref, result} when is_reference(ref), 5_000
    assert {:push, {:text, response}, _state} = Socket.handle_info({ref, result}, state)
    host_id = context.vm.host_id

    assert {:ok, {:res, %{id: 7, result: {:ok, %{"host_id" => ^host_id}}}}} =
             Envelope.decode(response)

    {:ok, _integration} =
      Galileo.configure_integration(
        %{
          name: "socket-lease",
          target: "https://api.example.test",
          headers: [%{kind: :bearer, name: "authorization", value: "secret"}],
          peer: false,
          idempotency_key: Ash.UUID.generate()
        },
        actor: context.owner
      )

    {:ok, _} =
      Galileo.attach_integration(%{name: "socket-lease", vm_id: context.vm.id},
        actor: context.owner
      )

    renew = %{"binding" => context.binding, "name" => "socket-lease"}
    request = Envelope.encode({:req, %{id: 8, op: "galileo.renew", body: renew}})
    assert {:ok, state} = Socket.handle_in({request, [opcode: :text]}, state)
    assert_receive {ref, result} when is_reference(ref), 5_000
    assert {:push, {:text, response}, _state} = Socket.handle_info({ref, result}, state)
    assert {:ok, {:res, %{id: 8, result: {:ok, %{"ttl" => ttl}}}}} = Envelope.decode(response)
    assert is_integer(ttl)
  end

  test "an unknown op is an error response, not a closed socket", context do
    {:push, {:text, _welcome}, state} = hello(socket(context))
    request = Envelope.encode({:req, %{id: 9, op: "galileo.nothing", body: %{}}})
    assert {:ok, state} = Socket.handle_in({request, [opcode: :text]}, state)
    assert_receive {ref, result} when is_reference(ref), 5_000
    assert {:push, {:text, response}, _} = Socket.handle_info({ref, result}, state)

    assert {:ok, {:res, %{id: 9, result: {:error, "invalid_request"}}}} =
             Envelope.decode(response)
  end

  test "hints and resyncs reach a bound socket only", context do
    state = socket(context)
    assert Socket.handle_info(:control_resync, state) == {:ok, state}
    {:push, {:text, _welcome}, bound} = hello(state)
    id = Ecto.UUID.generate()
    assert {:push, {:text, hint}, _} = Socket.handle_info({:control_hint, :user, id}, bound)
    assert Envelope.decode(hint) == {:ok, {:hint, %{kind: "user", id: id}}}
    assert {:push, {:text, resync}, _} = Socket.handle_info(:control_resync, bound)
    assert Envelope.decode(resync) == {:ok, :resync}
  end

  # @cc [owner:ghuntley,label:verification;protocol] control-client-server-end-to-end
  # The shared client MUST reach the real upgrade plug over verified TLS with
  # the headers it actually sends, bind, and complete a domain request.
  test "the shared client connects over verified TLS and completes a request", context do
    fixtures = Path.expand("../fixtures/tls", __DIR__)

    endpoint =
      start_supervised!(
        {Bandit,
         plug: MarshallWeb.ControlAPI,
         scheme: :https,
         ip: {127, 0, 0, 1},
         port: 0,
         startup_log: false,
         certfile: Path.join(fixtures, "localhost.pem"),
         keyfile: Path.join(fixtures, "localhost.key")}
      )

    {:ok, {_, port}} = ThousandIsland.listener_info(endpoint)
    token = context.token

    client =
      start_supervised!(
        {OverallsProtocol.Control.Client,
         [
           url: "https://localhost:#{port}",
           service: "galileo",
           credential: fn -> {:ok, token} end,
           bind: fn -> %{} end,
           cacertfile: Path.join(fixtures, "ca.pem"),
           owner: self()
         ]}
      )

    assert_receive {:control, ^client, {:connected, %{heartbeat_ms: 5_000}}}, 5_000
    host_id = context.vm.host_id

    assert {:ok, %{"host_id" => ^host_id}} =
             OverallsProtocol.Control.Client.request(client, "galileo.identity", %{})
  end
end
