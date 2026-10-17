defmodule Ziggy.Route do
  @moduledoc "Closed native provider routes. Guest input never selects an upstream origin."
  @type provider :: :openai | :anthropic
  @type query :: :none | :anthropic_beta
  @type route :: %{
          provider: provider(),
          path: binary(),
          query: query(),
          body: binary(),
          model: binary()
        }
  @paths %{
    "/v1/responses" => {:openai, "/v1/responses"},
    "/v1/chat/completions" => {:openai, "/v1/chat/completions"},
    "/v1/messages" => {:anthropic, "/v1/messages"},
    "/v1/messages/count_tokens" => {:anthropic, "/v1/messages/count_tokens"}
  }

  # @cc [owner:ghuntley,label:security] provider-route-closed
  # Only explicitly supported POST paths and JSON objects with bounded model
  # IDs may select inference. Provider prefixes MUST match the native endpoint.
  # Only empty queries or exact beta=true on Anthropic Messages/token counting
  # may resolve; the validated query MUST remain separate from the native path.
  # Unsupported features MUST fail before provider effects; request bodies MUST
  # remain byte-for-byte native, including unknown provider fields.
  @spec resolve(binary(), binary(), binary(), binary()) :: {:ok, route()} | {:error, atom()}
  def resolve("POST", path, query, body) when byte_size(body) <= 16_777_216 do
    with {:ok, provider, native} <- endpoint(path),
         {:ok, validated_query} <- query(provider, native, query),
         {:ok, %{"model" => model} = object} <- Jason.decode(body),
         true <- valid_model?(model),
         false <- unsupported?(provider, object) do
      {:ok, %{provider: provider, path: native, query: validated_query, body: body, model: model}}
    else
      {:error, :unsupported_route} = error -> error
      _ -> {:error, :invalid_request}
    end
  end

  def resolve(_, _, _, _), do: {:error, :unsupported_route}

  @spec origin(provider()) :: binary()
  def origin(:openai), do: "https://api.openai.com"
  def origin(:anthropic), do: "https://api.anthropic.com"

  @spec valid_model?(term()) :: boolean()
  def valid_model?(model) when is_binary(model),
    do: byte_size(model) in 1..256 and Regex.match?(~r/\A[a-zA-Z0-9][a-zA-Z0-9._:\/-]*\z/, model)

  def valid_model?(_), do: false

  defp endpoint(path) do
    case Map.fetch(@paths, path) do
      {:ok, {provider, native}} -> {:ok, provider, native}
      :error -> prefixed(path)
    end
  end

  defp prefixed("/openai" <> path), do: matching(path, :openai)
  defp prefixed("/anthropic" <> path), do: matching(path, :anthropic)
  defp prefixed(_), do: {:error, :unsupported_route}

  defp matching(path, expected) do
    case Map.fetch(@paths, path) do
      {:ok, {^expected, native}} -> {:ok, expected, native}
      _ -> {:error, :unsupported_route}
    end
  end

  @spec query(provider(), binary(), binary()) :: {:ok, query()} | {:error, :unsupported_route}
  defp query(_, _, ""), do: {:ok, :none}

  defp query(:anthropic, path, "beta=true")
       when path in ["/v1/messages", "/v1/messages/count_tokens"],
       do: {:ok, :anthropic_beta}

  defp query(_, _, _), do: {:error, :unsupported_route}

  defp unsupported?(:openai, object) do
    object["background"] == true or object["store"] == true or
      Map.has_key?(object, "previous_response_id") or Map.has_key?(object, "audio") or
      Enum.any?(List.wrap(object["modalities"]), &(&1 != "text"))
  end

  defp unsupported?(:anthropic, _), do: false
end
