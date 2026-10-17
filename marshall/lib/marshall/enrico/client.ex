defmodule Marshall.Enrico.Client do
  @moduledoc "Verified private transport to the Enrico cache API."
  @type response ::
          {:ok, map() | binary()}
          | {:error,
             :tls_untrusted
             | :timeout
             | :unauthorized
             | :service_unavailable
             | :not_found
             | :invalid_response}

  # @cc [owner:ghuntley,label:security] enrico-verified-service-transport
  # Marshall MUST use the pinned fleet certificate and a dedicated credential;
  # browser input can only select fixed API operations and encoded path segments.
  @spec request(atom(), binary(), binary() | nil, map()) :: response()
  def request(method, id, operation \\ nil, params \\ %{})
      when method in [:get, :post, :delete] do
    with true <- OverallsProtocol.uuid?(id),
         {:ok, endpoint, token, ca} <- settings(),
         {:ok, url} <- url(endpoint, id, operation, params),
         {:ok, response} <-
           Req.request(
             method: method,
             url: url,
             headers: [{"authorization", "Bearer " <> token}],
             json: if(method == :post, do: params, else: nil),
             connect_options: [transport_opts: [cacertfile: ca]],
             receive_timeout: 20_000,
             max_redirects: 0,
             retry: false,
             decode_body: operation != "blob"
           ) do
      case response.status do
        status when status in 200..299 -> {:ok, response.body}
        status when status in [401, 403] -> {:error, :unauthorized}
        404 -> {:error, :not_found}
        _ -> {:error, :service_unavailable}
      end
    else
      {:error, %Req.TransportError{reason: reason}} -> {:error, transport_reason(reason)}
      {:error, :unavailable} -> {:error, :service_unavailable}
      {:error, reason} when reason in [:not_found, :invalid_response] -> {:error, reason}
      {:error, _} -> {:error, :service_unavailable}
    end
  rescue
    _ -> {:error, :service_unavailable}
  end

  defp transport_reason(%Mint.TransportError{reason: {:tls_alert, _}}), do: :tls_untrusted
  defp transport_reason({:tls_alert, _}), do: :tls_untrusted
  defp transport_reason(%Mint.TransportError{reason: :timeout}), do: :timeout
  defp transport_reason(:timeout), do: :timeout
  defp transport_reason(_), do: :service_unavailable

  defp settings do
    endpoint = Application.get_env(:marshall, :enrico_url)
    token_file = Application.get_env(:marshall, :enrico_token_file)
    ca = Application.get_env(:marshall, :enrico_ca_file)

    with true <- is_binary(endpoint) and String.starts_with?(endpoint, "https://"),
         true <- is_binary(ca) and File.regular?(ca),
         true <- is_binary(token_file),
         {:ok, token} <- File.read(token_file),
         true <- byte_size(String.trim(token)) >= 32 do
      {:ok, endpoint, String.trim(token), ca}
    else
      _ -> {:error, :unavailable}
    end
  end

  defp url(endpoint, id, operation, params) do
    base = endpoint <> "/v1/repos/" <> id

    case operation do
      nil ->
        {:ok, base}

      "refresh" ->
        {:ok, base <> "/refresh"}

      "attempts/" <> attempt when byte_size(attempt) == 36 ->
        if OverallsProtocol.uuid?(attempt),
          do: {:ok, base <> "/attempts/" <> attempt},
          else: {:error, :invalid_response}

      value when value in ["tree", "blob", "history", "diff", "blame", "refs"] ->
        {:ok, base <> "/git/" <> value <> "?" <> URI.encode_query(params)}

      "search" ->
        {:ok, base <> "/search?" <> URI.encode_query(params)}

      _ ->
        {:error, :invalid_response}
    end
  end
end
