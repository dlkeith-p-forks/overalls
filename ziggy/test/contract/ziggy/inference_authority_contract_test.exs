defmodule ZiggyInferenceAuthorityContractTest do
  use Covenant.Case, component: "ziggy.inference_authority"

  @tag obligation: "ziggy.inference_authority.I1"
  test "declared modules compile and remain loadable" do
    modules = [
      Ziggy.AgentError,
      Ziggy.AgentStream,
      Ziggy.AgentWorker,
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

  @tag obligation: "ziggy.inference_authority.I5"
  test "streamed responses require a complete contiguous terminal output" do
    item = %{"type" => "message", "content" => []}

    gap_frame =
      "data: " <>
        Jason.encode!(%{
          "type" => "response.output_item.done",
          "output_index" => 1,
          "item" => item
        }) <> "\n\n"

    terminal_gap =
      "data: " <>
        Jason.encode!(%{
          "type" => "response.completed",
          "response" => %{"status" => "completed", "id" => "resp_1"}
        }) <> "\n\n"

    assert {:ok, gap} = Ziggy.AgentStream.feed(%Ziggy.AgentStream{}, gap_frame <> terminal_gap)
    assert {:error, :invalid_response} = Ziggy.AgentStream.finish(gap)

    item_frame =
      "data: " <>
        Jason.encode!(%{
          "type" => "response.output_item.done",
          "output_index" => 0,
          "item" => item
        }) <>
        "\n\n"

    terminal =
      "data: " <>
        Jason.encode!(%{
          "type" => "response.completed",
          "response" => %{"status" => "completed", "id" => "resp_2"}
        }) <> "\n\n"

    assert {:ok, stream} = Ziggy.AgentStream.feed(%Ziggy.AgentStream{}, item_frame <> terminal)
    assert {:ok, %{"output" => [^item]}} = Ziggy.AgentStream.finish(stream)

    assert {:ok, duplicate} = Ziggy.AgentStream.feed(stream, terminal)
    assert {:error, :invalid_response} = Ziggy.AgentStream.finish(duplicate)
  end
end
