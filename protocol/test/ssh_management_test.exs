defmodule OverallsProtocol.SSHManagementTest do
  use ExUnit.Case, async: true
  import Hegel, except: [draw: 2]
  import OverallsProtocol.TestProperties, only: [draw: 2]
  import Hegel.Gen

  test "command envelopes preserve the closed grammar and reject injected authority" do
    {:ok, command} = OverallsProtocol.SSHCommand.parse("new --name example --request-id retry-1")

    wire = %{
      "version" => command.version,
      "command" => command.command,
      "arguments" => command.arguments,
      "options" => command.options
    }

    body = %{"version" => 1, "session_token" => "session-fixture", "command" => wire}
    assert {:ok, %{command: ^wire}} = OverallsProtocol.SSHManagement.request("commands", body)

    assert {:error, :invalid_request} =
             OverallsProtocol.SSHManagement.request("commands", Map.put(body, "actor", "root"))

    assert {:error, :invalid_command} =
             OverallsProtocol.SSHManagement.request("commands", %{
               body
               | "command" => Map.put(wire, "owner_id", "root")
             })
  end

  alias OverallsProtocol.SSHManagement

  property "arbitrary envelopes never raise or accept client-selected authority",
    database: :disabled,
    print_blob: false,
    test_cases: 100,
    seed: 1_859_064_213 do
    value = draw("value", OverallsProtocol.TestGenerators.peer_term())

    route =
      draw("route", member_of(["ready", "sessions", "session", "close", "commands", "unknown"]))

    case SSHManagement.request(route, value) do
      {:ok, decoded} ->
        refute Map.has_key?(decoded, :actor)
        refute Map.has_key?(decoded, :user_id)

        expected =
          case route do
            "ready" -> 0
            "commands" -> 2
            _ -> 1
          end

        assert map_size(decoded) == expected

      {:error, reason} ->
        assert reason in [
                 :invalid_request,
                 :invalid_public_key,
                 :invalid_command,
                 :unsupported_version
               ]
    end
  end

  test "session routes reject unknown fields and versions" do
    valid = %{"version" => 1, "session_token" => "bounded-token"}
    assert {:ok, %{session_token: "bounded-token"}} = SSHManagement.request("session", valid)

    assert {:error, :invalid_request} =
             SSHManagement.request("session", Map.put(valid, "actor", "admin"))

    assert {:error, :unsupported_version} =
             SSHManagement.request("session", %{valid | "version" => 2})

    assert {:error, :invalid_request} =
             SSHManagement.request("session", %{
               valid
               | "session_token" => String.duplicate("x", 81)
             })
  end

  test "readiness accepts only its version and no client authority" do
    assert {:ok, %{}} = SSHManagement.request("ready", %{"version" => 1})

    for field <- ["actor", "session_token", "gateway_token", "user_id"] do
      assert {:error, :invalid_request} =
               SSHManagement.request("ready", %{"version" => 1, field => "injected"})
    end
  end
end
