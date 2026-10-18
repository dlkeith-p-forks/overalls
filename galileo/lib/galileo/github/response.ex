defmodule Galileo.GitHub.Response do
  @moduledoc "GitHub response projection with signed URL custody outside guests."
  alias Galileo.GitHub.{Capabilities, LFS}
  alias OverallsProtocol.GitHub

  @type json_value ::
          nil | boolean() | number() | String.t() | [json_value()] | %{String.t() => json_value()}
  @type context :: %{
          required(:binding) => map(),
          required(:lease) => GitHub.lease(),
          required(:capabilities) => GenServer.server(),
          optional(:route) => GitHub.route()
        }

  # @cc [owner:ghuntley,label:security] github-response-secret-url-redaction
  # Provider cookies/authentication challenges MUST never reach a guest.
  # Locations and pagination links MUST contain only internal fixed-provider
  # routes or opaque bound capabilities; signed URLs in JSON MUST be replaced
  # before any response bytes are emitted. Unsupported locations refuse.
  @spec headers([{String.t(), String.t()}], context()) ::
          {:ok, [{String.t(), String.t()}]} | {:error, :invalid_response}
  def headers(headers, context) do
    Enum.reduce_while(headers, {:ok, GitHub.response_headers(headers)}, fn
      {"location", value}, {:ok, safe} ->
        case location(value, context) do
          {:ok, value} -> {:cont, {:ok, [{"location", value} | safe]}}
          _ -> {:halt, {:error, :invalid_response}}
        end

      {"link", value}, {:ok, safe} ->
        case links(value, context) do
          {:ok, value} -> {:cont, {:ok, [{"link", value} | safe]}}
          _ -> {:halt, {:error, :invalid_response}}
        end

      _, result ->
        {:cont, result}
    end)
  end

  @spec location(String.t(), context()) :: {:ok, String.t()} | {:error, :invalid_response}
  def location(value, context) do
    case GitHub.internal_url(value) do
      {:ok, internal} -> {:ok, internal}
      _ -> capability(value, context)
    end
  end

  @spec json(binary(), context()) :: {:ok, binary()} | {:error, :invalid_response}
  def json(bytes, context) do
    with {:ok, decoded} <- Jason.decode(bytes),
         {:ok, decoded} <- LFS.rewrite(decoded, context),
         {:ok, safe} <- rewrite(decoded, context, 0),
         {:ok, bytes} <- Jason.encode(safe) do
      {:ok, bytes}
    else
      _ -> {:error, :invalid_response}
    end
  end

  @spec rewrite(json_value(), context(), non_neg_integer()) ::
          {:ok, json_value()} | {:error, :invalid_response}
  defp rewrite(_, _, depth) when depth > 32, do: {:error, :invalid_response}

  defp rewrite(value, context, _depth) when is_binary(value) do
    case GitHub.download_url(value) do
      {:ok, _} -> capability(value, context)
      _ -> if(GitHub.credential_url?(value), do: {:error, :invalid_response}, else: {:ok, value})
    end
  end

  defp rewrite(values, context, depth) when is_list(values) do
    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, safe} ->
      case rewrite(value, context, depth + 1) do
        {:ok, value} -> {:cont, {:ok, [value | safe]}}
        error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  defp rewrite(values, context, depth) when is_map(values) do
    Enum.reduce_while(values, {:ok, %{}}, fn {key, value}, {:ok, safe} ->
      case rewrite(value, context, depth + 1) do
        {:ok, value} -> {:cont, {:ok, Map.put(safe, key, value)}}
        error -> {:halt, error}
      end
    end)
  end

  defp rewrite(value, _context, _depth), do: {:ok, value}

  @spec capability(String.t(), context()) :: {:ok, String.t()} | {:error, :invalid_response}
  defp capability(url, context) do
    case Capabilities.mint(url, context.binding, context.lease, context.capabilities) do
      {:ok, path} -> {:ok, "https://" <> GitHub.hostname() <> path}
      _ -> {:error, :invalid_response}
    end
  end

  @spec links(String.t(), context()) :: {:ok, String.t()} | {:error, :invalid_response}
  defp links(value, context) when byte_size(value) <= 16_384 do
    matches = Regex.scan(~r/<([^<>]+)>([^<>]*)/, value)

    if matches != [] and Enum.map_join(matches, &hd/1) == value and
         not Regex.match?(~r/[\x00-\x1f\x7f]/, value) do
      Enum.reduce_while(matches, {:ok, ""}, fn [_, url, parameters], {:ok, projected} ->
        with true <-
               Regex.match?(
                 ~r/\A(?:\s*;\s*[A-Za-z0-9_-]+=(?:"[^"\r\n]*"|[A-Za-z0-9_-]+))*\s*,?\s*\z/,
                 parameters
               ),
             {:ok, safe} <- location(url, context) do
          {:cont, {:ok, projected <> "<" <> safe <> ">" <> parameters}}
        else
          _ -> {:halt, {:error, :invalid_response}}
        end
      end)
    else
      {:error, :invalid_response}
    end
  end

  defp links(_, _), do: {:error, :invalid_response}
end
