ExUnit.start()
Code.require_file("fixture.ex", __DIR__)
Code.require_file("terminal.ex", __DIR__)

defmodule OverallsAntithesis.TerminalTest do
  use ExUnit.Case, async: true

  alias OverallsAntithesis.Terminal

  @request_id "11111111-1111-4111-8111-111111111111"
  @create_id "22222222-2222-4222-8222-222222222222"
  @vm_id "33333333-3333-4333-8333-333333333333"

  @type request :: %{required(String.t()) => String.t() | integer()}

  @spec request(String.t()) :: request()
  defp request(operation) do
    %{
      "version" => 1,
      "operation" => operation,
      "request_id" => @request_id,
      "actor" => "admin_a"
    }
  end

  test "accepts only the four fixed terminal schemas" do
    create =
      request("terminal.create")
      |> Map.put("create_request_id", @create_id)
      |> Map.put("vm_id", @vm_id)

    assert {:ok, :create} = Terminal.parse_request("terminal.create", create)

    get = request("terminal.get") |> Map.put("create_request_id", @create_id)
    assert {:ok, :get} = Terminal.parse_request("terminal.get", get)

    for {name, expected} <- [{"terminal.ticket", :ticket}, {"terminal.kill", :kill}] do
      action = request(name) |> Map.put("session_id", @create_id)
      assert {:ok, ^expected} = Terminal.parse_request(name, action)
    end
  end

  test "rejects caller-selected payloads, actors and mismatched operations" do
    create =
      request("terminal.create")
      |> Map.put("create_request_id", @create_id)
      |> Map.put("vm_id", @vm_id)

    assert {:error, :invalid_request} =
             Terminal.parse_request("terminal.create", Map.put(create, "command", "id"))

    assert {:error, :invalid_request} =
             Terminal.parse_request("terminal.create", Map.put(create, "actor", "root"))

    assert {:error, :invalid_request} = Terminal.parse_request("terminal.kill", create)

    assert {:error, :invalid_request} =
             Terminal.parse_request("terminal.create", Map.put(create, "vm_id", "not-a-uuid"))
  end
end
