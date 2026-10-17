defmodule OverallsProtocol.InceptionPublic do
  @moduledoc "Bounded public DNS and issuer configuration supplied by the parent operator."
  @fields ~w(issuer accept_terms nameservers mailbox issuer_ca_pem trust_pem)

  # @cc [owner:ghuntley,label:security] inception-public-operator-settings
  # Public settings MUST contain only the closed issuer/trust/DNS schema, explicit
  # consent, and two to eight distinct IPv4 authoritative endpoints and names.
  # No credential, private key, path, arbitrary listener or child address may be
  # supplied. Nil disables public bootstrap. PEM validation here bounds public
  # certificate envelopes; TLS consumers MUST still validate the actual roots.
  @spec validate(term()) :: {:ok, map() | nil} | {:error, :invalid_inception_public}
  def validate(nil), do: {:ok, nil}

  def validate(value) when is_map(value) and map_size(value) == 6 do
    with true <- Map.keys(value) -- @fields == [],
         true <- issuer?(value["issuer"]) and value["accept_terms"] === true,
         true <- name?(value["mailbox"]),
         peers when is_list(peers) <- value["nameservers"],
         true <- length(peers) in 2..8 and Enum.all?(peers, &peer?/1),
         true <- Enum.uniq_by(peers, & &1["name"]) == peers,
         true <- Enum.uniq_by(peers, & &1["address"]) == peers,
         true <- pem?(value["issuer_ca_pem"]) and pem?(value["trust_pem"]),
         true <- byte_size(JSON.encode!(value)) <= 60_000 do
      {:ok, value}
    else
      _ -> {:error, :invalid_inception_public}
    end
  end

  def validate(_), do: {:error, :invalid_inception_public}

  defp peer?(%{"name" => name, "address" => address, "port" => port} = peer)
       when map_size(peer) == 3 and is_binary(address) and byte_size(address) in 7..15 and
              is_integer(port) and port in 1..65_535 do
    with true <- name?(name),
         {:ok, {a, _, _, _} = ip} <- :inet.parse_ipv4strict_address(String.to_charlist(address)),
         true <- a in 1..223 and List.to_string(:inet.ntoa(ip)) == address do
      true
    else
      _ -> false
    end
  end

  defp peer?(_), do: false

  defp issuer?(value) when is_binary(value) and byte_size(value) in 1..2048 do
    with true <-
           String.starts_with?(value, "https://") and Regex.match?(~r/\A[\x21-\x7e]+\z/, value),
         {:ok, uri} <- URI.new(value) do
      uri.scheme == "https" and name?(uri.host) and is_nil(uri.userinfo) and
        is_nil(uri.fragment) and uri.port in 1..65_535
    else
      _ -> false
    end
  end

  defp issuer?(_), do: false

  defp name?(value) when is_binary(value) and byte_size(value) in 1..253 do
    Enum.all?(String.split(value, "."), fn part ->
      byte_size(part) in 1..63 and Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]*[a-z0-9])?\z/, part)
    end)
  end

  defp name?(_), do: false
  defp pem?(nil), do: true

  defp pem?(value) when is_binary(value) and byte_size(value) in 1..16_384,
    do:
      Regex.match?(
        ~r/\A(?:-----BEGIN CERTIFICATE-----\n[A-Za-z0-9+\/=\n]+-----END CERTIFICATE-----\n?)+\z/,
        value
      )

  defp pem?(_), do: false
end
