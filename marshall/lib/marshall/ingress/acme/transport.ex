defmodule Marshall.Ingress.ACME.Transport do
  @moduledoc "Verified, bounded single-issuer ACME exchanges without implicit retries."
  alias Marshall.Ingress.ACME.{AccountKey, JWS}
  @derive {Inspect, only: []}
  @enforce_keys [:directory, :origin]
  defstruct [:directory, :origin, :cacertfile]
  @type t :: %__MODULE__{directory: binary(), origin: tuple(), cacertfile: binary() | nil}
  @type result ::
          {:ok, %{status: integer(), body: binary(), location: binary() | nil}}
          | {:error,
             atom()
             | %{
                 status: integer(),
                 retry_after_ms: non_neg_integer() | nil,
                 type: :bad_nonce | :rate_limited | :other
               }}
  @maximum 524_288

  @spec new(term(), keyword()) :: {:ok, t()} | {:error, :invalid_issuer}
  def new(directory, options \\ []) do
    ca = Keyword.get(options, :cacertfile)

    if JWS.https_url?(directory) and (is_nil(ca) or is_binary(ca)),
      do: {:ok, %__MODULE__{directory: directory, origin: origin(directory), cacertfile: ca}},
      else: {:error, :invalid_issuer}
  end

  @spec directory(t()) :: {:ok, map()} | {:error, term()}
  def directory(client) do
    with {:ok, %{status: 200, body: body}} <- request(client, :get, client.directory, nil),
         true <- byte_size(body) <= 65_536,
         {:ok, value} when is_map(value) <- Jason.decode(body),
         routes = Map.take(value, ["newNonce", "newAccount", "newOrder"]),
         true <-
           map_size(routes) == 3 and Enum.all?(routes, fn {_, url} -> trusted?(client, url) end) do
      {:ok, routes}
    else
      {:error, %Jason.DecodeError{}} -> {:error, :invalid_directory}
      {:error, _} = error -> error
      _ -> {:error, :invalid_directory}
    end
  end

  # @cc [owner:ghuntley,label:security;protocol] acme-issuer-transport
  # All exchanges MUST verify HTTPS at the configured issuer origin, bound time
  # and response bytes, and disable redirects, decompression and implicit retries.
  # Each signed operation MUST obtain a new nonce by HEAD and use it only in its
  # one POST attempt. Responses MUST NOT implicitly trigger another signed POST.
  # Errors MUST omit bodies, URLs, key material and request signatures. Resource
  # URLs (including account kid and returned Location) MUST remain same-origin.
  @spec post(t(), AccountKey.t(), term(), term(), term(), term()) :: result()
  def post(client, key, nonce_url, url, identity, payload) do
    Logger.metadata(marshall_authentication: true)

    with true <- trusted?(client, nonce_url) and trusted?(client, url),
         true <- identity == :new_account or trusted_identity?(client, identity),
         {:ok, nonce} <- nonce(client, nonce_url),
         {:ok, body} <- JWS.sign(key, url, nonce, identity, payload) do
      request(client, :post, url, body)
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_issuer}
    end
  end

  defp nonce(client, url) do
    with {:ok, response} <- exchange(client, :head, url, nil),
         true <- response.status in [200, 204],
         [value] when byte_size(value) in 1..256 <-
           Req.Response.get_header(response, "replay-nonce"),
         {:ok, bytes} <- Base.url_decode64(value, padding: false),
         true <- Base.url_encode64(bytes, padding: false) == value do
      {:ok, value}
    else
      _ -> {:error, :nonce_unavailable}
    end
  end

  defp request(client, method, url, body) do
    with {:ok, response} <- exchange(client, method, url, body),
         {:ok, location} <- location(client, response) do
      if response.status in 200..299 do
        {:ok, %{status: response.status, body: response.body, location: location}}
      else
        {:error,
         %{
           status: response.status,
           retry_after_ms: retry_after(response),
           type: problem(response.body)
         }}
      end
    end
  end

  defp problem(body) do
    case Jason.decode(body) do
      {:ok, %{"type" => "urn:ietf:params:acme:error:badNonce"}} -> :bad_nonce
      {:ok, %{"type" => "urn:ietf:params:acme:error:rateLimited"}} -> :rate_limited
      _ -> :other
    end
  end

  defp exchange(client, method, url, body) do
    Logger.metadata(marshall_authentication: true)
    tls = [inet6: false] ++ if(client.cacertfile, do: [cacertfile: client.cacertfile], else: [])

    Req.request(
      method: method,
      url: url,
      body: body,
      headers: [{"content-type", "application/jose+json"}, {"accept-encoding", "identity"}],
      retry: false,
      redirect: false,
      decode_body: false,
      raw: true,
      compressed: false,
      connect_options: [timeout: 1500, transport_opts: tls],
      receive_timeout: 2000,
      request_timeout: 3000,
      into: &chunk/2
    )
    |> case do
      {:ok, %{body: :too_large}} ->
        {:error, :message_too_large}

      {:ok, response} ->
        if Req.Response.get_header(response, "content-encoding") in [[], ["identity"]],
          do: {:ok, response},
          else: {:error, :unsupported_encoding}

      _ ->
        {:error, :transport_error}
    end
  rescue
    _ -> {:error, :transport_error}
  catch
    _, _ -> {:error, :transport_error}
  end

  defp chunk({:data, bytes}, {request, response}) do
    if byte_size(response.body) + byte_size(bytes) <= @maximum,
      do: {:cont, {request, %{response | body: response.body <> bytes}}},
      else: {:halt, {request, %{response | body: :too_large}}}
  end

  defp retry_after(response) do
    case Req.Response.get_header(response, "retry-after") do
      [value] when byte_size(value) <= 128 -> Req.Response.get_retry_after(response)
      _ -> nil
    end
  rescue
    _ -> nil
  end

  defp location(client, response) do
    case Req.Response.get_header(response, "location") do
      [] -> {:ok, nil}
      [url] -> if trusted?(client, url), do: {:ok, url}, else: {:error, :invalid_issuer}
      _ -> {:error, :invalid_issuer}
    end
  end

  defp trusted_identity?(client, {:account, kid}), do: trusted?(client, kid)
  defp trusted_identity?(_, _), do: false
  defp trusted?(client, url), do: JWS.https_url?(url) and origin(url) == client.origin

  defp origin(url) do
    uri = URI.parse(url)
    {uri.scheme, String.downcase(uri.host), uri.port}
  end
end
