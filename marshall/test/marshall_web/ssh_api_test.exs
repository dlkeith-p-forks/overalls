defmodule MarshallWeb.SSHAPITest do
  use MarshallWeb.ConnCase, async: false
  import Hegel
  import Hegel.Gen
  @endpoint MarshallWeb.FleetEndpoint
  import Marshall.ComputeFixtures, only: [user: 0]
  import ExUnit.CaptureLog
  alias Marshall.Authorization.SystemActor
  alias Marshall.SSH
  import Marshall.PorscheSocket, only: [reply: 2]
  alias Marshall.PorscheSocket

  setup do
    {token, _} = SSH.Token.issue(:gateway)
    {:ok, _} = SSH.configure_gateway(%{name: "api", token: token}, actor: SystemActor.compute())
    key = "ssh-ed25519 " <> Base.encode64(<<11::32, "ssh-ed25519", 32::32, 11::256>>)
    %{gateway_token: token, public_key: key, user: user()}
  end

  test "Porsche accepts team list and member objects through the management API", c do
    {:ok, _} = SSH.add_key(%{public_key: c.public_key}, actor: c.user)
    opened = api(c, "sessions", %{version: 1, public_key: c.public_key}) |> reply(200)
    {:ok, client} = Porsche.Client.new("https://control.example.test", c.gateway_token)

    request = fn _client, route, payload, _options ->
      {:ok, api(c, route, payload) |> reply(200)}
    end

    empty =
      Porsche.Runner.run(client, opened["session_token"], "team list --json", request: request)

    assert empty.exit_status == 0
    assert empty.response["result"] == %{"items" => [], "next_cursor" => nil}

    {:ok, first} =
      Marshall.Teams.create_team(%{name: "cli-first", idempotency_key: "cli-first"},
        actor: c.user
      )

    {:ok, second} =
      Marshall.Teams.create_team(%{name: "cli-second", idempotency_key: "cli-second"},
        actor: c.user
      )

    listed =
      Porsche.Runner.run(client, opened["session_token"], "team list --json", request: request)

    assert listed.exit_status == 0

    assert Enum.sort(Enum.map(listed.response["result"]["items"], & &1["id"])) ==
             Enum.sort([first.id, second.id])

    assert {:ok, [latest]} = Marshall.Teams.list_teams(%{limit: 1}, actor: c.user)

    assert {:ok, [older]} =
             Marshall.Teams.list_teams(%{after: latest.id, limit: 1}, actor: c.user)

    refute older.id == latest.id
    assert {:ok, []} = Marshall.Teams.list_teams(%{after: older.id, limit: 1}, actor: c.user)

    shown =
      Porsche.Runner.run(client, opened["session_token"], "team show cli-first --json",
        request: request
      )

    assert shown.exit_status == 0
    assert [%{"user_id" => id, "role" => "owner"}] = shown.response["result"]["members"]
    assert id == c.user.id
  end

  test "Porsche accepts empty and populated integration pages without exposing secrets", c do
    {:ok, _} = SSH.add_key(%{public_key: c.public_key}, actor: c.user)
    opened = api(c, "sessions", %{version: 1, public_key: c.public_key}) |> reply(200)
    {:ok, client} = Porsche.Client.new("https://control.example.test", c.gateway_token)

    request = fn _client, route, payload, _options ->
      {:ok, api(c, route, payload) |> reply(200)}
    end

    Hegel.check(
      fn ->
        count = draw("count", integer(0..4))

        integrations =
          for _ <- List.duplicate(:integration, count) do
            {:ok, integration} =
              Marshall.Galileo.configure_integration(
                %{
                  name: "live" <> Ash.UUID.generate(),
                  target: "https://origin.example.test",
                  headers: [%{kind: :bearer, name: "authorization", value: "private-page-secret"}],
                  idempotency_key: Ash.UUID.generate()
                },
                actor: c.user
              )

            integration
          end

        result =
          Porsche.Runner.run(client, opened["session_token"], "integration list --json",
            request: request
          )

        assert result.exit_status == 0
        assert %{"items" => items, "next_cursor" => nil} = result.response["result"]

        assert Enum.sort(Enum.map(items, & &1["id"])) ==
                 Enum.sort(Enum.map(integrations, & &1.id))

        refute JSON.encode!(result.response) =~ "private-page-secret"

        assert Enum.all?(
                 items,
                 &(&1["headers"] == [%{"kind" => "bearer", "name" => "authorization"}])
               )

        for integration <- integrations do
          assert {:ok, _} =
                   Marshall.Galileo.remove_integration(%{name: integration.name}, actor: c.user)
        end
      end,
      test_cases: 100
    )
  end

  test "management API lists and provisions Ubuntu with idempotent image selection", c do
    fixture = Marshall.ComputeFixtures.host_fixture()
    ubuntu = Marshall.ComputeFixtures.ubuntu_image_fixture(fixture)
    {:ok, _} = SSH.add_key(%{public_key: c.public_key}, actor: c.user)
    opened = api(c, "sessions", %{version: 1, public_key: c.public_key}) |> reply(200)
    {:ok, images} = OverallsProtocol.SSHCommand.parse("images --json")
    body = %{version: 1, session_token: opened["session_token"], command: images}
    catalog = api(c, "commands", body) |> reply(200)
    assert Enum.any?(catalog["result"]["images"], &(&1["id"] == ubuntu.id))

    {:ok, command} =
      OverallsProtocol.SSHCommand.parse(
        "new --image #{ubuntu.id} --request-id ubuntu-api --no-wait --json"
      )

    created = api(c, "commands", %{body | command: command}) |> reply(200)
    repeated = api(c, "commands", %{body | command: command}) |> reply(200)
    assert created["operation_id"] == repeated["operation_id"]

    assert [%{image_id: selected, owner_id: owner}] =
             Marshall.Compute.Ledger.read!(Marshall.Compute.VirtualMachine)

    assert selected == ubuntu.id
    assert owner == c.user.id

    assert api(%{c | gateway_token: "invalid"}, "commands", %{body | command: command})
           |> reply(401)
  end

  test "structured commands cannot bypass the disk cap", c do
    {:ok, _} = SSH.add_key(%{public_key: c.public_key}, actor: c.user)
    opened = api(c, "sessions", %{version: 1, public_key: c.public_key}) |> reply(200)
    command = %{version: 1, command: "new", arguments: [], options: %{"disk" => "501"}}
    body = %{version: 1, session_token: opened["session_token"], command: command}
    assert api(c, "commands", body) |> reply(400) == %{"error" => "invalid_command"}
    assert Marshall.Compute.Ledger.read!(Marshall.Compute.VirtualMachine) == []
    assert Marshall.Compute.Ledger.read!(Marshall.Compute.Operation) == []
  end

  test "Customer sharing is a policy refusal with no effects rather than service unavailability",
       c do
    Marshall.ComputeFixtures.host_fixture()

    {:ok, vm} =
      Marshall.Compute.provision(Marshall.ComputeFixtures.request(%{profile: :customer}),
        actor: c.user
      )

    recipient = user()
    {:ok, _} = SSH.add_key(%{public_key: c.public_key}, actor: c.user)
    opened = api(c, "sessions", %{version: 1, public_key: c.public_key}) |> reply(200)

    {:ok, command} =
      OverallsProtocol.SSHCommand.parse(
        "share add #{vm.id} #{recipient.email} viewer --request-id denied-customer-share"
      )

    assert api(c, "commands", %{
             version: 1,
             session_token: opened["session_token"],
             command: command
           })
           |> reply(403) == %{"error" => "forbidden"}

    assert Marshall.Compute.Ledger.read!(Marshall.Access.Grant, vm_id: vm.id) == []
    assert Marshall.Compute.Ledger.read!(Marshall.Access.Change, vm_id: vm.id) == []
    assert Marshall.Compute.Ledger.read!(Marshall.Access.Grant.Version) == []
    assert Marshall.Compute.Ledger.read!(SSH.Request, request_id: "denied-customer-share") == []
  end

  test "admission diagnostics retain a closed reason without command or credentials", c do
    old_level = Logger.level()
    Logger.configure(level: :info)
    on_exit(fn -> Logger.configure(level: old_level) end)
    {:ok, _} = SSH.add_key(%{public_key: c.public_key}, actor: c.user)
    opened = api(c, "sessions", %{version: 1, public_key: c.public_key}) |> reply(200)
    marker = "private-admission-marker"
    image = "sha256:" <> String.duplicate("0", 64)
    {:ok, command} = OverallsProtocol.SSHCommand.parse("new --name #{marker} --image #{image}")

    logs =
      capture_log([level: :info, format: "$metadata$message", metadata: [:event, :reason]], fn ->
        assert api(c, "commands", %{
                 version: 1,
                 session_token: opened["session_token"],
                 command: command
               })
               |> reply(409) == %{"error" => "image_unavailable"}
      end)

    assert logs =~ "event=api.request_unauthorized"
    # The closed catalogued reason survives authentication filtering; the
    # command, image, session and gateway credentials never do.
    assert logs =~ "reason=image_unavailable"
    refute logs =~ marker
    refute logs =~ image
    refute logs =~ opened["session_token"]
    refute logs =~ c.gateway_token
  end

  test "the gateway opens, polls and closes a session through its own credential", c do
    {:ok, _} = SSH.add_key(%{public_key: c.public_key}, actor: c.user)
    opened = api(c, "sessions", %{version: 1, public_key: c.public_key}) |> reply(200)
    assert opened["status"] == "authenticated"
    assert opened["user"]["id"] == c.user.id
    payload = %{version: 1, session_token: opened["session_token"]}

    assert api(c, "session", payload) |> reply(200) |> Map.fetch!("status") ==
             "authenticated"

    assert api(c, "close", payload) |> reply(200) |> Map.fetch!("closed")
    assert api(c, "session", payload) |> reply(401) == %{"error" => "unauthorized"}
  end

  test "readiness authenticates current gateway authority without opening sessions", c do
    assert http(c, "ready", %{version: 1}) |> json_response(200) == %{"ready" => true}
    assert Marshall.Compute.Ledger.read!(SSH.Session) == []
    assert Marshall.Compute.Ledger.read!(SSH.Approval) == []
    assert {:error, _} = SSH.gateway_ready(%{gateway_token: c.gateway_token}, actor: c.user)
    {replacement, _} = SSH.Token.issue(:gateway)

    {:ok, gateway} =
      SSH.configure_gateway(%{name: "api", token: replacement}, actor: SystemActor.compute())

    assert http(c, "ready", %{version: 1}) |> json_response(401) == %{"error" => "unauthorized"}
    current = %{c | gateway_token: replacement}
    assert http(current, "ready", %{version: 1}) |> json_response(200) == %{"ready" => true}
    {:ok, _} = SSH.disable_gateway(%{id: gateway.id}, actor: SystemActor.compute())

    assert http(current, "ready", %{version: 1}) |> json_response(401) == %{
             "error" => "unauthorized"
           }
  end

  test "readiness rejects a missing release migration", c do
    Ecto.Adapters.SQL.query!(Marshall.Repo, "DELETE FROM schema_migrations WHERE version = $1", [
      Marshall.Operations.Health.required_version()
    ])

    assert http(c, "ready", %{version: 1}) |> json_response(503) == %{
             "error" => "temporarily_unavailable"
           }
  end

  test "unknown keys get a bounded approval destination, never an account", c do
    response = api(c, "sessions", %{version: 1, public_key: c.public_key}) |> reply(200)
    assert response["status"] == "pending"
    assert String.starts_with?(response["approval_path"], "/ssh/approve/porsche_approval_")
    refute Map.has_key?(response, "user")
  end

  test "commands use session identity and return fixed domain errors", c do
    {:ok, _} = SSH.add_key(%{public_key: c.public_key}, actor: c.user)
    opened = api(c, "sessions", %{version: 1, public_key: c.public_key}) |> reply(200)
    {:ok, command} = OverallsProtocol.SSHCommand.parse("whoami --json")
    body = %{version: 1, session_token: opened["session_token"], command: command}
    reply = api(c, "commands", body) |> reply(200)
    assert reply["result"]["id"] == c.user.id
    {:ok, missing} = OverallsProtocol.SSHCommand.parse("request show missing")

    assert api(c, "commands", %{body | command: missing}) |> reply(404) == %{
             "error" => "request_not_found"
           }

    assert api(c, "commands", Map.put(body, :actor, "root")) |> reply(400) == %{
             "error" => "invalid_request"
           }

    assert api(c, "close", %{version: 1, session_token: opened["session_token"]})
           |> reply(200)

    assert api(c, "commands", body) |> reply(401) == %{"error" => "unauthorized"}
  end

  test "unknown fields, oversized input, invalid credentials and versions fail closed", c do
    assert api(c, "sessions", %{version: 1, public_key: c.public_key, actor: "root"})
           |> reply(400) == %{"error" => "invalid_request"}

    assert api(c, "sessions", %{version: 2, public_key: c.public_key}) |> reply(426) == %{
             "error" => "unsupported_version"
           }

    {wrong, _} = SSH.Token.issue(:gateway)

    assert api(%{c | gateway_token: wrong}, "sessions", %{version: 1, public_key: c.public_key})
           |> reply(401) == %{"error" => "unauthorized"}

    response =
      build_conn()
      |> put_req_header("authorization", "Bearer " <> c.gateway_token)
      |> put_req_header("content-type", "application/json")
      |> post("/api/ssh/v1/host-certificate", String.duplicate(" ", 16_385))

    assert json_response(response, 413) == %{"error" => "message_too_large"}

    for route <- ~w(sessions session close commands) do
      assert http(c, route, %{version: 1}) |> json_response(400) == %{
               "error" => "invalid_request"
             }
    end
  end

  test "forwarded HTTPS does not authenticate a remote plaintext connection", c do
    conn =
      %{build_conn() | remote_ip: {192, 0, 2, 1}}
      |> put_req_header("x-forwarded-proto", "https")
      |> put_req_header("authorization", "Bearer " <> c.gateway_token)
      |> put_req_header("content-type", "application/json")
      |> post("/api/ssh/v1/ready", Jason.encode!(%{version: 1}))

    assert json_response(conn, 403) == %{"error" => "https_required"}
  end

  test "invalid gateway credentials emit a catalogued unauthorized event without the token", c do
    invalid =
      "porsche_gateway_" <> Base.url_encode64(:crypto.strong_rand_bytes(32), padding: false)

    logs =
      capture_log([metadata: [:event, :reason]], fn ->
        assert http(%{c | gateway_token: invalid}, "ready", %{version: 1})
               |> json_response(401) == %{"error" => "unauthorized"}
      end)

    assert logs =~ "event=api.request_unauthorized"
    refute String.contains?(logs, invalid)
  end

  # Gateway session and command routes run over the control socket
  # (ADR-0142); only readiness and host certificates remain HTTPS routes.
  defp api(c, route, payload), do: PorscheSocket.request(c.gateway_token, route, payload)

  defp http(c, route, payload) do
    build_conn()
    |> put_req_header("authorization", "Bearer " <> c.gateway_token)
    |> put_req_header("content-type", "application/json")
    |> post("/api/ssh/v1/" <> route, Jason.encode!(payload))
  end

  test "gateway credentials and approval links are absent from debug diagnostics", c do
    old_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: old_level) end)
    parent = self()

    logs =
      capture_log(fn ->
        result = api(c, "sessions", %{version: 1, public_key: c.public_key}) |> reply(200)
        send(parent, {:approval_path, result["approval_path"]})
      end)

    assert_receive {:approval_path, path}
    refute String.contains?(logs, c.gateway_token)
    refute String.contains?(logs, path)
  end

  test "command arguments and session credentials are absent from debug diagnostics", c do
    {:ok, _} = SSH.add_key(%{public_key: c.public_key}, actor: c.user)
    opened = api(c, "sessions", %{version: 1, public_key: c.public_key}) |> reply(200)
    marker = "private-request-marker"
    {:ok, command} = OverallsProtocol.SSHCommand.parse("request show #{marker}")
    old_level = Logger.level()
    Logger.configure(level: :debug)
    on_exit(fn -> Logger.configure(level: old_level) end)

    logs =
      capture_log(fn ->
        assert api(c, "commands", %{
                 version: 1,
                 session_token: opened["session_token"],
                 command: command
               })
               |> reply(404)
      end)

    refute String.contains?(logs, marker)
    refute String.contains?(logs, opened["session_token"])
    refute String.contains?(logs, c.gateway_token)
  end
end
