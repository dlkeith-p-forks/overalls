defmodule Susan.Provider.Finch do
  @moduledoc """
  Finch transport for the fixed provider origins, verified against the system
  trust store. APNs requires HTTP/2; the Google token and FCM endpoints use
  HTTP/1.1 or HTTP/2 as negotiated.
  """
  @behaviour Susan.Provider.HTTP

  @max_response 65_536

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_options) do
    # Middlebox compatibility mode is off: the OTP 29 TLS 1.3 client otherwise
    # aborts against servers that omit the dummy ChangeCipherSpec (observed in
    # the susan-service machine test); it adds nothing for direct HTTPS.
    tls = [
      transport_opts: [
        cacerts: :public_key.cacerts_get(),
        verify: :verify_peer,
        middlebox_comp_mode: false
      ]
    ]

    pools =
      Map.new(Susan.Provider.origins(), fn origin ->
        if String.contains?(origin, "push.apple.com"),
          do: {origin, [protocols: [:http2], count: 2, conn_opts: tls]},
          else: {origin, [protocols: [:http1], size: 4, count: 1, conn_opts: tls]}
      end)

    Finch.child_spec(
      name: __MODULE__.Pool,
      pools: Map.put(pools, :default, size: 1, conn_opts: tls)
    )
  end

  # @cc [owner:ghuntley,label:security;privacy] susan-fixed-provider-egress
  # Provider requests MUST go only to the compiled APNs, Google OAuth and FCM
  # origins over verified TLS; no request-supplied value selects an origin.
  @impl true
  def request(:post, url, headers, body) do
    if Susan.Provider.allowed_url?(url) do
      request = Finch.build(:post, url, headers, body)

      case Finch.request(request, __MODULE__.Pool, receive_timeout: 10_000, pool_timeout: 5_000) do
        {:ok, %Finch.Response{status: status, headers: response_headers, body: response}} ->
          {:ok, status, Enum.map(response_headers, fn {k, v} -> {String.downcase(k), v} end),
           binary_part(response, 0, min(byte_size(response), @max_response))}

        {:error, _} ->
          {:error, :transport}
      end
    else
      {:error, :transport}
    end
  rescue
    _ -> {:error, :transport}
  end
end
