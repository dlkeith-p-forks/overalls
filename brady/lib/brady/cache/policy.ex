defmodule Brady.Cache.Policy do
  @moduledoc "Conservative shared-cache admission with explicit freshness and exact variant identity."
  @type headers :: [{String.t(), String.t()}]
  @type request :: %{
          method: String.t(),
          scheme: :http | :https,
          host: String.t(),
          port: pos_integer(),
          target: String.t(),
          headers: headers()
        }
  @request_denials ~w(authorization proxy-authorization cookie range if-range if-match if-none-match if-modified-since if-unmodified-since cache-control pragma)
  @anonymous_headers ~w(host accept accept-encoding accept-language user-agent connection content-length)
  @response_denials ~w(set-cookie content-range www-authenticate proxy-authenticate)
  @vary ~w(accept accept-encoding accept-language)
  @flags ~w(public immutable must-revalidate proxy-revalidate)
  @numbers ~w(max-age s-maxage)

  # @cc [owner:ghuntley,label:security] brady-cache-anonymous-request
  # Requests containing credentials, cookies, query strings, conditions, ranges
  # or client cache controls MUST fail this admission predicate. Cache.lookup/3
  # may remove only Range/If-Range before checking anonymity, then select bytes
  # from a fresh complete representation under Range.select/3. Other refusals
  # MUST apply to both lookup and storage. Authority verification remains a
  # mandatory precondition at the connection boundary.
  @spec eligible?(request()) :: boolean()
  def eligible?(request) do
    request.method == "GET" and request.scheme in [:http, :https] and
      is_binary(request.target) and String.starts_with?(request.target, "/") and
      not String.contains?(request.target, ["?", "#", "\r", "\n"]) and
      Enum.all?(@request_denials, &(values(request.headers, &1) == [])) and
      Enum.all?(request.headers, fn {name, _} -> String.downcase(name) in @anonymous_headers end)
  end

  # @cc [owner:ghuntley,label:security] brady-cache-explicit-freshness
  # Admission MUST require status 200, explicit public freshness (or the reviewed
  # anonymous commit-pinned archive normalization), no sensitive
  # response headers and unambiguous supported Vary. Age MUST include upstream
  # age, apparent age and response delay; expired objects MUST not be admitted.
  @spec admit(request(), integer(), headers(), integer(), integer()) :: {:ok, map()} | :bypass
  def admit(request, status, headers, sent_at, received_at) do
    headers = Brady.Cache.Archive.headers(request, headers)

    with true <- eligible?(request) and status == 200,
         true <- is_integer(sent_at) and is_integer(received_at) and received_at >= sent_at,
         true <- Enum.all?(@response_denials, &(values(headers, &1) == [])),
         {:ok, directives} <- directives(headers),
         true <- Map.has_key?(directives, "public"),
         ttl when is_integer(ttl) <- Map.get(directives, "s-maxage", directives["max-age"]),
         {:ok, date} <- date(headers),
         {:ok, age} <- age(headers),
         {:ok, vary} <- vary(headers),
         corrected_age = max(max(0, received_at - date), age + received_at - sent_at),
         true <- ttl > corrected_age do
      {:ok,
       %{
         key: key(request, vary),
         vary: vary,
         stored_at: received_at,
         initial_age: corrected_age,
         lifetime: ttl,
         expires_at: received_at + ttl - corrected_age,
         headers: headers
       }}
    else
      _ -> :bypass
    end
  end

  @spec fresh?(map(), integer()) :: boolean()
  def fresh?(entry, now), do: now >= entry.stored_at and now < entry.expires_at

  @spec current_age(map(), integer()) :: non_neg_integer()
  def current_age(entry, now), do: entry.initial_age + max(0, now - entry.stored_at)

  # @cc [owner:ghuntley,label:security] brady-cache-origin-variant-separation
  # Cache identity MUST include scheme, exact validated authority/port, target
  # and all selected request variant fields, preserving missing versus empty.
  # Request values MUST NOT become filesystem paths.
  @spec key(request(), [String.t()]) :: String.t()
  def key(request, vary) do
    identity =
      {request.scheme, String.downcase(request.host), request.port, request.target,
       Enum.map(Enum.sort(vary), &{&1, values(request.headers, &1)})}

    :crypto.hash(:sha256, :erlang.term_to_binary(identity)) |> Base.encode16(case: :lower)
  end

  @spec values(headers(), String.t()) :: [String.t()]
  def values(headers, name) do
    for {key, value} <- headers, String.downcase(key) == name, do: value
  end

  defp directives(headers) do
    case values(headers, "cache-control") do
      [] ->
        :error

      fields ->
        fields
        |> Enum.join(",")
        |> String.split(",")
        |> Enum.reduce_while({:ok, %{}}, fn item, {:ok, acc} ->
          case directive(String.trim(item)) do
            {:ok, name, value} ->
              if Map.has_key?(acc, name),
                do: {:halt, :error},
                else: {:cont, {:ok, Map.put(acc, name, value)}}

            _ ->
              {:halt, :error}
          end
        end)
    end
  end

  defp directive(item) do
    case String.split(String.downcase(item), "=", parts: 2) do
      [flag] when flag in @flags ->
        {:ok, flag, true}

      [name, value] when name in @numbers ->
        case decimal(value) do
          {:ok, number} -> {:ok, name, number}
          _ -> :error
        end

      _ ->
        :error
    end
  end

  defp decimal(value) do
    if byte_size(value) <= 10 and Regex.match?(~r/\A[0-9]+\z/, value),
      do: {:ok, String.to_integer(value)},
      else: :error
  end

  defp age(headers) do
    case values(headers, "age") do
      [] -> {:ok, 0}
      [value] -> decimal(value)
      _ -> :error
    end
  end

  defp date(headers) do
    case values(headers, "date") do
      [value] when byte_size(value) <= 64 ->
        case :httpd_util.convert_request_date(String.to_charlist(value)) do
          {{_, _, _}, {_, _, _}} = date ->
            {:ok, :calendar.datetime_to_gregorian_seconds(date) - 62_167_219_200}

          _ ->
            :error
        end

      _ ->
        :error
    end
  rescue
    _ -> :error
  end

  defp vary(headers) do
    names =
      values(headers, "vary")
      |> Enum.join(",")
      |> String.downcase()
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)

    if length(names) <= 3 and Enum.all?(names, &(&1 in @vary)) and
         length(Enum.uniq(names)) == length(names), do: {:ok, Enum.sort(names)}, else: :error
  end
end
