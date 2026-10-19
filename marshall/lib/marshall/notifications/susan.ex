defmodule Marshall.Notifications.Susan do
  @moduledoc """
  HTTPS client for the Susan push relay's poke endpoint (ADR-0224).

  The origin is the compiled constant `https://notifications.overalls.dev`,
  verified against the operating system trust store. Only a `MIX_ENV=test`
  build reads an override (`config :marshall, Marshall.Notifications.Susan`),
  so no runtime configuration can redirect pokes to another host.
  """
  alias OverallsProtocol.SusanPoke

  @origin "https://notifications.overalls.dev"
  @path "/api/push/v1/poke"
  @timeout 10_000

  @type outcome ::
          {:ok, non_neg_integer()}
          | {:retry, :transport | :timeout | :server_error | :rate_limited, non_neg_integer(),
             non_neg_integer() | nil}
          | {:invalidated, non_neg_integer()}
          | {:rejected, non_neg_integer()}

  # @cc [owner:ghuntley,label:security] susan-fixed-origin
  # Production builds MUST send pokes only to the compiled Susan origin over
  # verified TLS using the system trust store. The test override MUST exist
  # only when compiled with MIX_ENV=test.
  if Mix.env() == :test do
    @doc "The Susan origin. Test builds honour `config :marshall, #{inspect(__MODULE__)}, origin: ...`."
    @spec origin() :: String.t()
    def origin, do: Keyword.get(test_config(), :origin, @origin)

    defp request_options, do: Keyword.get(test_config(), :req_options, [])
    defp test_config, do: Application.get_env(:marshall, __MODULE__, [])
  else
    @doc "The Susan origin, a compiled constant."
    @spec origin() :: String.t()
    def origin, do: @origin

    defp request_options, do: []
  end

  @doc "The compiled production origin, independent of any test override."
  @spec production_origin() :: String.t()
  def production_origin, do: @origin

  @doc """
  Sends one signed poke body and classifies the response (ADR-0225):
  2xx delivered; 404/410 invalidates the device; 429 and 5xx, transport and
  timeout failures retry (honouring `Retry-After` seconds); other statuses are
  permanent refusals.
  """
  @spec poke(binary(), %{key: String.t(), signature: String.t()}) :: outcome()
  def poke(body, %{key: key, signature: signature}) when is_binary(body) do
    [
      method: :post,
      url: origin() <> @path,
      body: body,
      headers: [
        {"content-type", "application/json"},
        {SusanPoke.key_header(), key},
        {SusanPoke.signature_header(), signature}
      ],
      retry: false,
      redirect: false,
      decode_body: false,
      receive_timeout: @timeout,
      connect_options: [timeout: @timeout, transport_opts: transport_options()]
    ]
    |> Keyword.merge(request_options())
    |> Req.request()
    |> classify()
  rescue
    _ -> {:retry, :transport, 0, nil}
  end

  @spec transport_options() :: keyword()
  defp transport_options do
    [verify: :verify_peer, cacerts: :public_key.cacerts_get(), depth: 4]
  end

  @doc "Maps a Req result to a delivery outcome."
  @spec classify({:ok, Req.Response.t()} | {:error, term()}) :: outcome()
  def classify({:ok, %Req.Response{status: status}}) when status in 200..299, do: {:ok, status}

  def classify({:ok, %Req.Response{status: status}}) when status in [404, 410],
    do: {:invalidated, status}

  def classify({:ok, %Req.Response{status: 429} = response}),
    do: {:retry, :rate_limited, 429, retry_after(response)}

  def classify({:ok, %Req.Response{status: status} = response}) when status in 500..599,
    do: {:retry, :server_error, status, retry_after(response)}

  def classify({:ok, %Req.Response{status: status}}) when is_integer(status),
    do: {:rejected, status}

  def classify({:error, %Req.TransportError{reason: :timeout}}), do: {:retry, :timeout, 0, nil}
  def classify({:error, _}), do: {:retry, :transport, 0, nil}

  @doc "Parses a delta-seconds `Retry-After`, bounded to one hour."
  @spec retry_after(Req.Response.t()) :: non_neg_integer() | nil
  def retry_after(response) do
    with [value | _] <- Req.Response.get_header(response, "retry-after"),
         true <- Regex.match?(~r/\A[0-9]{1,6}\z/, value) do
      min(String.to_integer(value), 3600)
    else
      _ -> nil
    end
  end
end
