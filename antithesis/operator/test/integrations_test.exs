Code.require_file("../fixture.ex", __DIR__)
Code.require_file("../integrations.ex", __DIR__)

ExUnit.start()

defmodule OverallsAntithesis.IntegrationsTest do
  use ExUnit.Case, async: true

  alias OverallsAntithesis.Integrations

  @request_id "12345678-1234-4234-8234-123456789abc"
  @vm_id "87654321-4321-4321-8321-cba987654321"

  test "only the five fixed operations accept exact request fields" do
    for operation <- ~w(integration.create integration.retarget integration.rotate) do
      request = %{"version" => 1, "request_id" => @request_id, "operation" => operation}
      assert {:ok, ^request} = Integrations.validate_request(request, operation)

      assert {:error, :invalid_request} =
               Integrations.validate_request(
                 Map.put(request, "target", "https://elsewhere.test"),
                 operation
               )
    end

    for operation <- ~w(integration.attach integration.detach) do
      request = %{
        "version" => 1,
        "request_id" => @request_id,
        "operation" => operation,
        "vm_id" => @vm_id
      }

      assert {:ok, ^request} = Integrations.validate_request(request, operation)

      assert {:error, :invalid_request} =
               Integrations.validate_request(Map.delete(request, "vm_id"), operation)
    end
  end

  test "untrusted actor, target, secret, malformed UUID and unknown operation are refused" do
    request = %{
      "version" => 1,
      "request_id" => @request_id,
      "operation" => "integration.create"
    }

    for {field, value} <- [
          {"actor", "admin_b"},
          {"origin", "https://integration-b.fixture.test"},
          {"header", "secret"},
          {"vm_id", @vm_id}
        ] do
      assert {:error, :invalid_request} =
               Integrations.validate_request(Map.put(request, field, value), "integration.create")
    end

    assert {:error, :invalid_request} =
             Integrations.validate_request(
               %{request | "request_id" => "bad"},
               "integration.create"
             )

    assert {:error, :invalid_request} =
             Integrations.validate_request(
               %{request | "operation" => "integration.remove"},
               "integration.remove"
             )
  end
end
