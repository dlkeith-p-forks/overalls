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

    assert {:error, :unsupported_route} =
             Ziggy.Route.resolve("POST", "/v1/responses", "", String.duplicate("x", 16_777_217))
  end

  @tag obligation: "ziggy.inference_authority.I3"
  test "provider errors classify into closed reasons" do
    assert :context_length_exceeded =
             Ziggy.AgentError.classify(%{"code" => "context_length_exceeded"})

    assert :cancelled = Ziggy.AgentError.terminal(%{"status" => "cancelled"})
    assert :upstream_failed = Ziggy.AgentError.classify(%{"message" => "secret"})
  end

  @tag obligation: "ziggy.inference_authority.I4"
  test "lease rejects unsafe authority parameters before starting" do
    owner = self()

    base = [
      owner: owner,
      request_id: "00000000-0000-0000-0000-000000000001",
      renew: fn -> :ok end,
      tasks: self()
    ]

    assert {:stop, :invalid_lease} = Ziggy.Lease.init(Keyword.merge(base, ttl_ms: 0))

    assert {:stop, :invalid_lease} =
             Ziggy.Lease.init(Keyword.merge(base, ttl_ms: 31_000, renewal_ms: 1))

    assert {:stop, :invalid_lease} =
             Ziggy.Lease.init(Keyword.merge(base, ttl_ms: 100, renewal_ms: 100))

    assert {:stop, :invalid_lease} = Ziggy.Lease.init(Keyword.put(base, :request_id, "bad"))
  end
end
