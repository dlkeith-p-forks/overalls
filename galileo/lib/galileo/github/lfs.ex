defmodule Galileo.GitHub.LFS do
  @moduledoc "Typed basic LFS batch projection; transfer credentials remain at the edge."
  alias Galileo.GitHub.Capabilities
  alias OverallsProtocol.{GitHub, Integration}

  @type json :: Galileo.GitHub.Response.json_value()
  @type context :: Galileo.GitHub.Response.context()

  # @cc [owner:ghuntley,label:security] github-lfs-action-custody
  # Every successful LFS basic batch action MUST become a method-bound opaque
  # capability. Its provider headers and signed URL MUST NOT reach the guest.
  # Each action binds its repository, SHA256 object ID, size and bounded expiry;
  # unknown actions, transports, targets and malformed external fields refuse.
  @spec rewrite(json(), context()) :: {:ok, json()} | {:error, :invalid_response}
  def rewrite(value, %{route: %{kind: :git, path: path}} = context) do
    if String.ends_with?(path, "/info/lfs/objects/batch"),
      do: batch(value, context, String.replace_suffix(path, "/objects/batch", "")),
      else: {:ok, value}
  end

  def rewrite(value, _context), do: {:ok, value}

  @spec batch(json(), context(), String.t()) :: {:ok, json()} | {:error, :invalid_response}
  defp batch(%{"objects" => objects} = batch, context, repository)
       when is_list(objects) and length(objects) <= 1000 do
    if Map.get(batch, "transfer", "basic") == "basic" do
      Enum.reduce_while(objects, {:ok, []}, fn object, {:ok, safe} ->
        case object(object, context, repository) do
          {:ok, value} -> {:cont, {:ok, [value | safe]}}
          _ -> {:halt, {:error, :invalid_response}}
        end
      end)
      |> case do
        {:ok, values} -> {:ok, Map.put(batch, "objects", Enum.reverse(values))}
        error -> error
      end
    else
      {:error, :invalid_response}
    end
  end

  # Provider errors have no transfer authority and are projected normally.
  defp batch(%{"message" => message} = value, _, _) when is_binary(message), do: {:ok, value}
  defp batch(_, _, _), do: {:error, :invalid_response}

  @spec object(json(), context(), String.t()) :: {:ok, json()} | {:error, :invalid_response}
  defp object(%{"oid" => oid, "size" => size} = value, context, repository)
       when is_binary(oid) and is_integer(size) and size >= 0 and
              size <= 9_223_372_036_854_775_807 do
    with true <- Regex.match?(~r/\A[a-f0-9]{64}\z/, oid),
         actions when is_map(actions) and map_size(actions) <= 3 <- Map.get(value, "actions", %{}),
         object = %{oid: oid, size: size, repository: repository},
         {:ok, actions} <- actions(actions, object, context) do
      {:ok,
       if(Map.has_key?(value, "actions"), do: Map.put(value, "actions", actions), else: value)}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp object(_, _, _), do: {:error, :invalid_response}

  @spec actions(map(), Capabilities.object(), context()) ::
          {:ok, map()} | {:error, :invalid_response}
  defp actions(actions, object, context) do
    Enum.reduce_while(actions, {:ok, %{}}, fn {name, value}, {:ok, safe} ->
      with method when is_binary(method) <- action_method(name),
           {:ok, action} <- action(value, method, object, context) do
        {:cont, {:ok, Map.put(safe, name, action)}}
      else
        _ -> {:halt, {:error, :invalid_response}}
      end
    end)
  end

  @spec action(json(), String.t(), Capabilities.object(), context()) ::
          {:ok, map()} | {:error, :invalid_response}
  defp action(%{"href" => href} = value, method, object, context) when is_binary(href) do
    with true <-
           Enum.all?(Map.keys(value), &(&1 in ["href", "header", "expires_in", "expires_at"])),
         headers when is_map(headers) and map_size(headers) <= 16 <- Map.get(value, "header", %{}),
         {:ok, headers} <- headers(headers),
         {:ok, ttl} <- ttl(value),
         {:ok, path} <-
           Capabilities.mint_transfer(
             %{url: href, method: method, headers: headers, object: object, ttl: ttl},
             context.binding,
             context.lease,
             context.capabilities
           ) do
      {:ok,
       %{
         "href" => "https://" <> GitHub.hostname() <> path,
         "header" => %{},
         "expires_in" => div(ttl, 1000)
       }}
    else
      _ -> {:error, :invalid_response}
    end
  end

  defp action(_, _, _, _), do: {:error, :invalid_response}

  @spec headers(map()) :: {:ok, [{String.t(), String.t()}]} | {:error, :invalid_response}
  defp headers(headers) do
    Enum.reduce_while(headers, {:ok, []}, fn {name, value}, {:ok, safe} ->
      with true <- is_binary(name) and is_binary(value),
           {:ok, {name, value}} <- Integration.header([String.downcase(name), value]) do
        {:cont, {:ok, [{name, value} | safe]}}
      else
        _ -> {:halt, {:error, :invalid_response}}
      end
    end)
  end

  @spec ttl(map()) :: {:ok, pos_integer()} | {:error, :invalid_response}
  defp ttl(value) do
    seconds = Map.get(value, "expires_in", 60)

    with true <- is_integer(seconds) and seconds > 0,
         {:ok, remaining} <- remaining(Map.get(value, "expires_at")),
         ttl = min(min(seconds * 1000, remaining), 60_000),
         true <- ttl > 0 do
      {:ok, ttl}
    else
      _ -> {:error, :invalid_response}
    end
  end

  @spec remaining(nil | json()) :: {:ok, integer()} | {:error, :invalid_response}
  defp remaining(nil), do: {:ok, 60_000}

  defp remaining(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _} -> {:ok, DateTime.diff(datetime, DateTime.utc_now(), :millisecond)}
      _ -> {:error, :invalid_response}
    end
  end

  defp remaining(_), do: {:error, :invalid_response}

  @spec action_method(term()) :: String.t() | nil
  defp action_method("download"), do: "GET"
  defp action_method("upload"), do: "PUT"
  defp action_method("verify"), do: "POST"
  defp action_method(_), do: nil
end
