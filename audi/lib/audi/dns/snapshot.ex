defmodule Audi.DNS.Snapshot do
  @moduledoc "Closed complete-publication envelope received from Marshall."
  @derive {Inspect, only: [:revision, :expires_at]}
  @enforce_keys [:revision, :expires_at, :entries]
  defstruct [:revision, :expires_at, :entries]

  @type t :: %__MODULE__{
          revision: non_neg_integer(),
          expires_at: integer(),
          entries: %{binary() => Audi.DNS.Directory.entry()}
        }

  # @cc [owner:ghuntley,label:security;protocol] audi-complete-dns-snapshot
  # A snapshot MUST bind the configured zone and contain only canonical unique
  # VM or single-layer Inception owners, at most eight distinct canonical IPv4s per route and two distinct
  # SHA-256 proofs per challenge. Each collection and their label union MUST be
  # bounded to 10,000 publication owners. Unknown fields or duplicate owners reject the whole
  # snapshot. All deadlines MUST derive from request start, never receipt time.
  @spec decode(term(), binary(), integer()) ::
          {:ok, t()} | {:error, :invalid_message | :expired_response}
  def decode(value, zone, started) do
    with %{
           "version" => 1,
           "zone" => ^zone,
           "revision" => revision,
           "ttl" => ttl,
           "routes" => routes,
           "proofs" => proofs
         }
         when map_size(value) == 6 <- value,
         true <- valid_zone?(zone),
         true <- is_integer(revision) and revision in 0..9_223_372_036_854_775_807,
         true <- lifetime?(ttl, 5000) and bounded?(routes) and bounded?(proofs),
         {:ok, addresses} <- records(routes, zone, started, ttl, :route),
         {:ok, challenges} <- records(proofs, zone, started, ttl, :proof),
         true <- MapSet.size(MapSet.new(Map.keys(addresses) ++ Map.keys(challenges))) <= 10_000 do
      entries =
        Map.new(addresses, fn {label, entry} -> {label <> "." <> zone, entry} end)
        |> Map.merge(
          Map.new(challenges, fn {label, entry} ->
            owner =
              if label == "",
                do: "_acme-challenge." <> zone,
                else: "_acme-challenge." <> label <> "." <> zone

            {owner, entry}
          end)
        )

      if started + ttl > System.monotonic_time(:millisecond),
        do: {:ok, %__MODULE__{revision: revision, expires_at: started + ttl, entries: entries}},
        else: {:error, :expired_response}
    else
      _ -> {:error, :invalid_message}
    end
  end

  defp records(values, zone, started, maximum, kind) do
    Enum.reduce_while(values, {:ok, %{}}, fn record, {:ok, acc} ->
      with %{"label" => label, "ttl" => ttl} <- record,
           true <-
             (kind == :proof and label == "") or
               (kind == :proof and
                  OverallsProtocol.InceptionName.wildcard_proof_owner?(label)) or
               (kind == :route and route_label?(label)) or
               (kind == :proof and OverallsProtocol.InceptionName.publication?(label)),
           owner =
             if(label == "",
               do: "_acme-challenge." <> zone,
               else: "_acme-challenge." <> label <> "." <> zone
             ),
           true <- byte_size(owner) <= 253,
           false <- Map.has_key?(acc, label),
           true <- lifetime?(ttl, maximum),
           {:ok, entry} <- entry(record, kind, started + ttl) do
        {:cont, {:ok, Map.put(acc, label, entry)}}
      else
        _ -> {:halt, :error}
      end
    end)
  end

  defp entry(%{"addresses" => addresses} = value, :route, expiry)
       when map_size(value) == 3 and is_list(addresses) do
    if length(addresses) in 1..8 and Enum.uniq(addresses) == addresses do
      Enum.reduce_while(addresses, {:ok, []}, fn address, {:ok, acc} ->
        with true <- is_binary(address) and byte_size(address) in 1..45 and String.valid?(address),
             {:ok, ip} <- :inet.parse_ipv4strict_address(String.to_charlist(address)),
             true <- List.to_string(:inet.ntoa(ip)) == address do
          {:cont, {:ok, [ip | acc]}}
        else
          _ -> {:halt, :error}
        end
      end)
      |> case do
        {:ok, ips} -> {:ok, %{addresses: Enum.reverse(ips), expires_at: expiry}}
        _ -> :error
      end
    else
      :error
    end
  end

  defp entry(%{"proofs" => proofs} = value, :proof, expiry)
       when map_size(value) == 3 and is_list(proofs) do
    if length(proofs) in 1..2 and Audi.DNS.Challenge.proofs?(proofs),
      do: {:ok, %{challenges: proofs, expires_at: expiry}},
      else: :error
  end

  defp entry(_, _, _), do: :error

  defp route_label?(label) when is_binary(label),
    do:
      not String.starts_with?(label, "e-") and
        (OverallsProtocol.InceptionName.publication?(label) or editor_publication?(label))

  defp route_label?(_), do: false

  defp editor_publication?("webview"), do: true
  defp editor_publication?("editor-" <> vm), do: OverallsProtocol.EditorRelease.digest?(vm, 32)
  defp editor_publication?(_), do: false
  defp bounded?(values), do: is_list(values) and length(values) <= 10_000
  defp lifetime?(ttl, maximum), do: is_integer(ttl) and ttl in 1..maximum

  defp valid_zone?(zone) when is_binary(zone) and byte_size(zone) in 1..253 do
    String.valid?(zone) and
      Enum.all?(String.split(zone, "."), fn label ->
        Regex.match?(~r/\A[a-z0-9](?:[a-z0-9-]{0,61}[a-z0-9])?\z/, label)
      end)
  end

  defp valid_zone?(_), do: false
end
