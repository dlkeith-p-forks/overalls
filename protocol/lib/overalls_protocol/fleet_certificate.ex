defmodule OverallsProtocol.FleetCertificate do
  @moduledoc "Closed version-one wildcard delivery and acknowledgement envelopes."

  @type bundle :: %{
          host_id: binary(),
          zone: binary(),
          generation: pos_integer(),
          fingerprint: binary(),
          expires_at: DateTime.t(),
          chain_pem: binary(),
          private_key_pem: binary()
        }

  # @cc [owner:ghuntley,label:security;protocol] wildcard-bundle-closed-envelope
  # The fetch request MUST carry no caller-selected identity or key material.
  # The acknowledgement MUST identify only a positive generation and SHA-256
  # fingerprint. Replies MUST bind the configured host and zone and enforce
  # finite PEM and lifetime bounds before a caller treats them as typed data.
  @spec request(binary(), term()) :: {:ok, map()} | {:error, :invalid_message}
  def request("fleet-certificate", %{"version" => 1} = value) when map_size(value) == 1,
    do: {:ok, %{}}

  def request(
        "fleet-certificate-ack",
        %{"version" => 1, "generation" => generation, "fingerprint" => fingerprint} = value
      )
      when map_size(value) == 3 do
    if positive?(generation) and digest?(fingerprint),
      do: {:ok, %{generation: generation, fingerprint: fingerprint}},
      else: {:error, :invalid_message}
  end

  def request(_, _), do: {:error, :invalid_message}

  @spec response(binary(), term(), binary(), binary()) ::
          {:ok, bundle() | map()} | {:error, :invalid_message}
  def response(
        "fleet-certificate",
        %{"version" => 1, "bundle" => bundle} = value,
        host,
        zone
      )
      when map_size(value) == 2 and is_map(bundle) and map_size(bundle) == 7 do
    with %{
           "host_id" => ^host,
           "zone" => ^zone,
           "generation" => generation,
           "fingerprint" => fingerprint,
           "expires_at" => expires,
           "chain_pem" => chain,
           "private_key_pem" => key
         } <- bundle,
         true <- OverallsProtocol.uuid?(host) and zone?(zone),
         true <- positive?(generation) and digest?(fingerprint) and is_binary(expires),
         true <- pem?(chain, 524_288) and pem?(key, 16_384),
         {:ok, expiry, 0} <- DateTime.from_iso8601(expires),
         true <- DateTime.compare(expiry, DateTime.utc_now()) == :gt do
      {:ok,
       %{
         host_id: host,
         zone: zone,
         generation: generation,
         fingerprint: fingerprint,
         expires_at: expiry,
         chain_pem: chain,
         private_key_pem: key
       }}
    else
      _ -> {:error, :invalid_message}
    end
  end

  def response(
        "fleet-certificate-ack",
        %{"version" => 1, "ack" => %{"host_id" => host, "generation" => generation}} = value,
        host,
        _zone
      )
      when map_size(value) == 2 do
    if OverallsProtocol.uuid?(host) and positive?(generation),
      do: {:ok, %{host_id: host, generation: generation}},
      else: {:error, :invalid_message}
  end

  def response(_, _, _, _), do: {:error, :invalid_message}

  defp positive?(value), do: is_integer(value) and value in 1..9_223_372_036_854_775_807

  defp digest?(value),
    do:
      is_binary(value) and byte_size(value) == 64 and String.valid?(value) and
        Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp pem?(value, max), do: is_binary(value) and byte_size(value) in 1..max

  defp zone?(value) when is_binary(value) and byte_size(value) in 1..189 do
    Enum.all?(String.split(value, "."), fn label ->
      byte_size(label) in 1..63 and
        Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/, label)
    end)
  end

  defp zone?(_), do: false
end
