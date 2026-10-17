defmodule Ziggy.RouteTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  @anthropic_paths [
    "/v1/messages",
    "/v1/messages/count_tokens",
    "/anthropic/v1/messages",
    "/anthropic/v1/messages/count_tokens"
  ]

  test "native bytes survive route resolution" do
    body = ~s({ "model": "gpt-test", "input": "synthetic", "future_field": true })

    assert {:ok, %{provider: :openai, path: "/v1/responses", query: :none, body: ^body}} =
             Ziggy.Route.resolve("POST", "/openai/v1/responses", "", body)

    assert {:error, :unsupported_route} =
             Ziggy.Route.resolve("POST", "/anthropic/v1/responses", "", body)
  end

  test "Anthropic beta queries retain the native path and unmodified body" do
    body = ~s({ "model": "claude-test", "messages": [], "future_field": true })

    for path <- @anthropic_paths, query <- ["", "beta=true"] do
      native = String.replace_prefix(path, "/anthropic", "")
      expected_query = if query == "", do: :none, else: :anthropic_beta

      assert {:ok,
              %{
                provider: :anthropic,
                path: ^native,
                query: ^expected_query,
                body: ^body,
                model: "claude-test"
              }} = Ziggy.Route.resolve("POST", path, query, body)
    end
  end

  test "beta is exact, cannot select OpenAI and cannot bypass route matching" do
    body = ~s({"model":"test"})

    for query <- [
          "beta=false",
          "beta=True",
          "beta=1",
          "beta",
          "beta=",
          "beta=true&beta=true",
          "beta=true&extra=1",
          "extra=1&beta=true",
          "beta=true&",
          "beta=%74rue",
          "%62eta=true",
          "beta=true;extra=1",
          " beta=true",
          "beta=true "
        ],
        path <- @anthropic_paths do
      assert {:error, :unsupported_route} = Ziggy.Route.resolve("POST", path, query, body)
    end

    for path <- [
          "/v1/responses",
          "/openai/v1/responses",
          "/v1/chat/completions",
          "/openai/v1/chat/completions",
          "/openai/v1/messages",
          "/anthropic/v1/responses",
          "/anthropic/v1/messages/",
          "/v1/models"
        ] do
      assert {:error, :unsupported_route} = Ziggy.Route.resolve("POST", path, "beta=true", body)
    end

    for method <- ["GET", "PUT", "DELETE"], path <- @anthropic_paths do
      assert {:error, :unsupported_route} = Ziggy.Route.resolve(method, path, "beta=true", body)
    end
  end

  test "storage, background, arbitrary origins and unsupported routes fail closed" do
    for field <- [
          %{"store" => true},
          %{"background" => true},
          %{"previous_response_id" => "resp_fake"},
          %{"audio" => %{}}
        ] do
      body = Jason.encode!(Map.put(field, "model", "gpt-test"))
      assert {:error, :invalid_request} = Ziggy.Route.resolve("POST", "/v1/responses", "", body)
    end

    for path <- [
          "https://evil.example/v1/responses",
          "/v1/images/generations",
          "/v1/responses/resp_fake",
          "/v1/responses/../models"
        ] do
      assert {:error, _} = Ziggy.Route.resolve("POST", path, "", ~s({"model":"gpt-test"}))
    end
  end

  property "unknown paths never become upstream destinations" do
    check all(path <- string(:alphanumeric, min_length: 1, max_length: 256)) do
      assert {:error, :unsupported_route} =
               Ziggy.Route.resolve("POST", "/" <> path, "", ~s({"model":"test"}))
    end
  end

  property "only the exact Anthropic beta query reaches a native route" do
    check all(
            query <- string(:printable, min_length: 1, max_length: 256),
            path <- member_of(@anthropic_paths)
          ) do
      result = Ziggy.Route.resolve("POST", path, query, ~s({"model":"test"}))

      if query == "beta=true",
        do: assert(match?({:ok, %{query: :anthropic_beta}}, result)),
        else: assert(result == {:error, :unsupported_route})
    end
  end
end
