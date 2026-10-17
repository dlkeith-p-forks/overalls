defmodule Audi.HTTP.Headers do
  @moduledoc "Bounded proxy headers and host-only guest cookies."
  @hop ~w(connection keep-alive proxy-authenticate proxy-authorization te trailer transfer-encoding upgrade content-length)
  @forward ~w(forwarded x-forwarded-for x-forwarded-host x-forwarded-proto x-forwarded-port x-real-ip x-original-host)
  @reserved "__host-audi_"

  # @cc [owner:ghuntley,label:security] audi-request-header-authority
  # Guest requests MUST exclude platform cookies, caller identity/forwarding
  # headers, hop-by-hop headers and all Connection-nominated fields. Host and
  # forwarding data MUST be rebuilt from validated origin/transport context.
  # Message framing belongs to the streaming encoder, never retained headers.
  # Ordinary guest credentials MUST remain available to guest applications.
  @spec request([{binary(), binary()}], map()) :: {:ok, [{binary(), binary()}]} | {:error, atom()}
  def request(headers, context) do
    with {:ok, headers} <- normalize(headers),
         true <-
           hostname?(context.host) and is_integer(context.port) and context.port in 1..65_535,
         ip = context.remote_ip |> :inet.ntoa() |> List.to_string(),
         true <- is_nil(context.user_id) or OverallsProtocol.uuid?(context.user_id),
         {:ok, cookies} <-
           if(MapSet.member?(excluded(headers, []), "cookie"),
             do: {:ok, []},
             else: cookies(headers)
           ) do
      peer_excluded = if Map.get(context, :source_vm_id), do: ["authorization"], else: []

      excluded =
        excluded(headers, ["host", "cookie", "x-overalls-source-vm" | peer_excluded ++ @forward])

      authority = context.host <> if(context.port == 443, do: "", else: ":#{context.port}")

      rebuilt = [
        {"host", authority},
        {"x-forwarded-host", authority},
        {"x-forwarded-proto", "https"},
        {"x-forwarded-port", Integer.to_string(context.port)},
        {"x-forwarded-for", ip}
      ]

      identity = if context.user_id, do: [{"x-audi-user-id", context.user_id}], else: []

      source =
        if Map.get(context, :source_vm_id),
          do: [{"x-overalls-source-vm", context.source_vm_id}],
          else: []

      true =
        is_nil(Map.get(context, :source_vm_id)) or OverallsProtocol.uuid?(context.source_vm_id)

      {:ok, clean(headers, excluded) ++ cookies ++ rebuilt ++ identity ++ source}
    else
      _ -> {:error, :invalid_headers}
    end
  rescue
    _ -> {:error, :invalid_headers}
  end

  # @cc [owner:ghuntley,label:security] audi-response-cookie-boundary
  # Guest responses MUST NOT set platform-reserved cookies or identity headers.
  # Guest Set-Cookie Domain attributes MUST be removed to make those cookies
  # host-only. Hop-by-hop/framing fields MUST be discarded before downstream
  # encoding, including fields named by Connection. Independent Set-Cookie
  # fields MUST remain separate; they cannot be comma-folded.
  @spec response([{binary(), binary()}]) :: {:ok, [{binary(), binary()}]} | {:error, atom()}
  def response(headers) do
    with {:ok, headers} <- normalize(headers) do
      headers = clean(headers, excluded(headers, ["cache-control", "expires"]))

      Enum.reduce_while(headers, {:ok, []}, fn
        {"set-cookie", value}, {:ok, acc} ->
          case set_cookie(value) do
            :drop -> {:cont, {:ok, acc}}
            {:ok, value} -> {:cont, {:ok, [{"set-cookie", value} | acc]}}
            :error -> {:halt, {:error, :invalid_headers}}
          end

        header, {:ok, acc} ->
          {:cont, {:ok, [header | acc]}}
      end)
      |> case do
        {:ok, values} -> {:ok, Enum.reverse(values)}
        error -> error
      end
    end
  end

  defp normalize(headers) when is_list(headers) and length(headers) <= 64 do
    if Enum.all?(headers, fn
         {key, value} when is_binary(key) and is_binary(value) ->
           byte_size(key) in 1..256 and byte_size(value) <= 8192 and
             Regex.match?(~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/, key) and
             String.valid?(value) and not Regex.match?(~r/[\x00-\x08\x0a-\x1f\x7f]/, value)

         _ ->
           false
       end) and
         Enum.reduce(headers, 0, fn {k, v}, n -> n + byte_size(k) + byte_size(v) end) <= 65_536,
       do: {:ok, Enum.map(headers, fn {k, v} -> {String.downcase(k), v} end)},
       else: {:error, :invalid_headers}
  end

  defp normalize(_), do: {:error, :invalid_headers}

  defp excluded(headers, extra) do
    named =
      for {"connection", value} <- headers,
          name <- String.split(String.downcase(value), ","),
          do: String.trim(name)

    MapSet.new(@hop ++ extra ++ named)
  end

  defp clean(headers, excluded),
    do:
      Enum.reject(headers, fn {key, _} ->
        MapSet.member?(excluded, key) or String.starts_with?(key, ["x-audi-", "x-forwarded-"])
      end)

  defp cookies(headers) do
    values =
      for {"cookie", value} <- headers, part <- String.split(value, ";"), do: String.trim(part)

    Enum.reduce_while(values, {:ok, []}, fn value, {:ok, acc} ->
      case pair(value) do
        {:ok, name} -> {:cont, {:ok, if(reserved?(name), do: acc, else: [value | acc])}}
        :error -> {:halt, {:error, :invalid_headers}}
      end
    end)
    |> case do
      {:ok, []} -> {:ok, []}
      {:ok, values} -> {:ok, [{"cookie", values |> Enum.reverse() |> Enum.join("; ")}]}
      error -> error
    end
  end

  defp set_cookie(value) do
    [first | attributes] = String.split(value, ";")

    with {:ok, name} <- pair(String.trim(first)) do
      if reserved?(name),
        do: :drop,
        else:
          {:ok,
           Enum.join(
             [
               String.trim(first)
               | Enum.reject(attributes, fn attr ->
                   attr
                   |> String.split("=", parts: 2)
                   |> hd()
                   |> String.trim()
                   |> String.downcase() == "domain"
                 end)
             ],
             ";"
           )}
    end
  end

  defp pair(value) do
    case String.split(value, "=", parts: 2) do
      [name, _] ->
        if Regex.match?(~r/\A[!#$%&'*+.^_`|~0-9A-Za-z-]+\z/, name), do: {:ok, name}, else: :error

      _ ->
        :error
    end
  end

  defp reserved?(name), do: String.starts_with?(String.downcase(name), @reserved)

  defp hostname?(value) when is_binary(value) and byte_size(value) <= 253,
    do:
      String.valid?(value) and
        Enum.all?(
          String.split(value, "."),
          &Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/, &1)
        )

  defp hostname?(_), do: false
end
