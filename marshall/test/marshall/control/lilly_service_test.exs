defmodule Marshall.Control.LillyServiceTest do
  use MarshallWeb.ConnCase, async: false
  use ExUnitProperties
  import Marshall.ComputeFixtures

  alias OverallsProtocol.Control.Envelope
  alias Marshall.Compute.{Credentials, Host, HostCredential, Ledger}
  alias Marshall.Control.Services.Lilly

  setup do
    fixture = host_fixture()
    {:ok, issued} = Credentials.rotate(fixture.host.id, 3600)
    Map.put(fixture, :issued, issued)
  end

  test "authentication and bind hold the credential's host", c do
    assert {:ok, %{host_id: host_id} = principal} = Lilly.authenticate(c.issued.token)
    assert host_id == c.host.id
    assert Lilly.authenticate(String.duplicate("x", 80)) == :refused
    assert Lilly.authenticate("short") == :refused

    assert {:ok, ^principal, [{:host, ^host_id}, {:host_commands, ^host_id}]} =
             Lilly.bind(principal, %{"host_id" => host_id})

    assert Lilly.bind(principal, %{"host_id" => Ecto.UUID.generate()}) == {:close, :refused}
    assert Lilly.bind(principal, %{"host_id" => host_id, "x" => 1}) == {:close, :refused}

    limits = Marshall.Control.Service.limits(Lilly)
    assert limits.in_flight == 64
    assert limits.inbound > OverallsProtocol.max_body()
    assert limits.frame > OverallsProtocol.max_body()
  end

  test "unknown routes, malformed documents and lost credentials keep their names", c do
    {:ok, principal} = Lilly.authenticate(c.issued.token)

    assert Lilly.handle_request("lilly.console", %{}, principal) ==
             {:error, "unsupported_version"}

    assert {:error, name} = Lilly.handle_request("lilly.exchange", %{"version" => 4}, principal)
    assert name in ["invalid_message", "invalid_request"]

    assert Lilly.handle_request("lilly.exchange", %{"version" => 3}, principal) ==
             {:error, "unsupported_version"}

    assert Lilly.handle_request("audi.identity", %{}, principal) == {:error, "invalid_request"}

    body = open_body(c)
    {:ok, _} = Credentials.revoke(c.host.id)

    assert {:error, "unauthorized"} =
             Lilly.handle_request("lilly.sessions", body, principal)
  end

  test "the fault gate refuses only listed ops, before any domain call", c do
    path = Path.join(System.tmp_dir!(), "fault-gate-#{System.unique_integer([:positive])}")
    File.write!(path, "lilly.relocation_keys\n")
    Application.put_env(:marshall, :control_fault_gate_file, path)

    on_exit(fn ->
      Application.delete_env(:marshall, :control_fault_gate_file)
      File.rm(path)
    end)

    assert Marshall.Control.FaultGate.blocked?("lilly.relocation_keys")
    refute Marshall.Control.FaultGate.blocked?("lilly.sessions")

    {:ok, principal} = Lilly.authenticate(c.issued.token)

    {:ok, state} =
      Marshall.Control.Socket.init(%{service: "lilly", module: Lilly, principal: principal})

    hello = Envelope.encode({:hello, %{service: "lilly", bind: %{"host_id" => c.host.id}}})

    {:push, {:text, _welcome}, state} =
      Marshall.Control.Socket.handle_in({hello, [opcode: :text]}, state)

    request = Envelope.encode({:req, %{id: 1, op: "lilly.relocation_keys", body: %{}}})

    assert {:push, {:text, response}, _state} =
             Marshall.Control.Socket.handle_in({request, [opcode: :text]}, state)

    assert Envelope.decode(response) ==
             {:ok, {:res, %{id: 1, result: {:error, "temporarily_unavailable"}}}}
  end

  test "Lilly socket requests keep the provisioner request telemetry", c do
    test = self()
    handler = "lilly-socket-telemetry-#{System.unique_integer([:positive])}"

    :ok =
      :telemetry.attach(
        handler,
        [:marshall, :control, :request],
        fn _event, measurements, metadata, _ ->
          send(test, {:telemetry, measurements, metadata})
        end,
        nil
      )

    on_exit(fn -> :telemetry.detach(handler) end)
    {:ok, principal} = Lilly.authenticate(c.issued.token)

    {:ok, state} =
      Marshall.Control.Socket.init(%{service: "lilly", module: Lilly, principal: principal})

    hello = Envelope.encode({:hello, %{service: "lilly", bind: %{"host_id" => c.host.id}}})

    {:push, {:text, _welcome}, state} =
      Marshall.Control.Socket.handle_in({hello, [opcode: :text]}, state)

    for {id, body, status} <- [{1, open_body(c), 200}, {2, %{"version" => 4}, 400}] do
      request = Envelope.encode({:req, %{id: id, op: "lilly.sessions", body: body}})
      {:ok, _state} = Marshall.Control.Socket.handle_in({request, [opcode: :text]}, state)
      assert_receive {:telemetry, %{duration: duration}, %{status: ^status}}, 5_000
      assert is_integer(duration) and duration >= 0
    end
  end

  # @cc [owner:ghuntley,label:verification;protocol] control-lilly-transport-equivalence
  # Opens and exchanges over the control socket MUST follow the session
  # ratchet the retired HTTPS routes did: the newest session exchanges, and
  # every superseded session is stale_connection.
  property "socket opens and exchanges follow the session ratchet" do
    check all(
            steps <-
              list_of(
                member_of([:open, :latest, :superseded]),
                min_length: 2,
                max_length: 7
              ),
            max_runs: 10
          ) do
      fixture = host_fixture()
      {:ok, issued} = Credentials.rotate(fixture.host.id, 3600)
      c = %{issued: issued, host: fixture.host}
      first = call(c, "sessions", open_body(c))
      assert {:ok, %{"session_id" => _}} = first

      Enum.reduce(steps, [elem(first, 1)], fn step, [latest | _] = sessions ->
        case step do
          :open ->
            assert {:ok, %{"session_id" => _} = session} =
                     call(c, "sessions", open_body(c))

            [session | sessions]

          :latest ->
            assert {:ok, %{"commands" => _}} =
                     call(c, "exchange", exchange_body(latest))

            sessions

          :superseded when length(sessions) > 1 ->
            assert call(c, "exchange", exchange_body(List.last(sessions))) ==
                     {:error, "stale_connection"}

            sessions

          :superseded ->
            sessions
        end
      end)
    end
  end

  @spec call(map(), String.t(), map()) :: {:ok, map()} | {:error, String.t()}
  defp call(c, action, body) do
    {:ok, principal} = Lilly.authenticate(c.issued.token)
    Lilly.handle_request("lilly." <> action, body, principal)
  end

  @spec open_body(map()) :: map()
  defp open_body(c) do
    [credential] = Ledger.read!(HostCredential, id: hd(String.split(c.issued.token, ":")))
    [host] = Ledger.read!(Host, id: credential.host_id)
    %{"version" => 4, "session_id" => Ash.UUID.generate(), "machine_id" => host.machine_id}
  end

  @spec exchange_body(map()) :: map()
  defp exchange_body(session) do
    %{
      "version" => 4,
      "session_id" => session["session_id"],
      "epoch" => session["epoch"],
      "report" => nil,
      "acknowledgements" => [],
      "outcomes" => []
    }
  end
end
