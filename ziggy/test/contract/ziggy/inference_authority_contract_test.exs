defmodule ZiggyInferenceAuthorityContractTest do
  use Covenant.Case, component: "ziggy.inference_authority"

  @tag obligation: "ziggy.inference_authority.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Ziggy.Control,
      Ziggy.Control.Link,
      Ziggy.Credential,
      Ziggy.HTTP,
      Ziggy.Lease,
      Ziggy.Route,
      Ziggy.Upstream
    ]

    assert Enum.all?(modules, &Code.ensure_loaded?/1)
  end

  @tag obligation: "ziggy.inference_authority.I2"
  test "route resolution is closed and validates models" do
    assert {:ok, %{provider: :openai, path: "/v1/responses"}} =
             Ziggy.Route.resolve("POST", "/v1/responses", "", ~s({"model":"gpt-4o"}))

    assert {:error, :unsupported_route} =
             Ziggy.Route.resolve("GET", "/v1/responses", "", ~s({"model":"gpt-4o"}))

    assert {:error, :invalid_request} =
             Ziggy.Route.resolve("POST", "/v1/responses", "", ~s({"model":"bad model"}))
  end

  @tag obligation: "ziggy.inference_authority.I3"
  test "provider errors classify into closed reasons" do
    assert :context_length_exceeded =
             Ziggy.AgentError.classify(%{"code" => "context_length_exceeded"})

    assert :cancelled = Ziggy.AgentError.terminal(%{"status" => "cancelled"})
    assert :upstream_failed = Ziggy.AgentError.classify(%{"message" => "secret"})
  end
end
