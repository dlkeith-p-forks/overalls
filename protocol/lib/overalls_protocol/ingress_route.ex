defmodule OverallsProtocol.IngressRoute do
  @moduledoc "Closed installed-certificate readiness reports, separate from access grants."
  @binding [
    "vm_id",
    "placement_id",
    "service_generation",
    "execution_epoch",
    "generation"
  ]
  @certificate ["certificate_fingerprint", "certificate_expires_at"]

  # @cc [owner:ghuntley,label:security;protocol] ingress-route-report-schema
  # Readiness requests MUST contain exactly the execution identity and bounded
  # certificate digest/UTC expiry. No addresses, user authority or route lifetime
  # may be supplied. Decoding does not prove installation; only the gateway's
  # validating producer may send reports and Marshall must recheck the current
  # wake-eligible VM tuple. This report MUST NOT prove running execution.
  @spec request(term()) :: {:ok, map()} | {:error, :invalid_request}
  def request(value) when is_map(value) and map_size(value) == 8 do
    with true <-
           Map.keys(value) |> Enum.sort() == Enum.sort(["version" | @binding ++ @certificate]),
         true <- value["version"] == 1,
         true <- OverallsProtocol.uuid?(value["vm_id"]),
         true <- OverallsProtocol.uuid?(value["placement_id"]),
         true <-
           Enum.all?(~w(service_generation execution_epoch generation), &positive?(value[&1])),
         fingerprint = Map.get(value, "certificate_fingerprint"),
         expiry = Map.get(value, "certificate_expires_at"),
         true <- digest?(fingerprint) and timestamp?(expiry) do
      {:ok,
       %{
         vm_id: value["vm_id"],
         placement_id: value["placement_id"],
         service_generation: value["service_generation"],
         execution_epoch: value["execution_epoch"],
         generation: value["generation"],
         certificate_fingerprint: fingerprint,
         certificate_expires_at: expiry
       }}
    else
      _ -> {:error, :invalid_request}
    end
  end

  def request(_), do: {:error, :invalid_request}

  @spec positive?(term()) :: boolean()
  defp positive?(value),
    do: is_integer(value) and value in 1..9_223_372_036_854_775_807

  @spec response(term()) :: {:ok, map()} | {:error, :invalid_message}
  def response(%{"version" => 1, "route" => route} = envelope) when map_size(envelope) == 2 do
    with %{
           "id" => id,
           "revision" => revision,
           "label" => label,
           "expires_at" => expiry,
           "certificate_fingerprint" => fingerprint
         }
         when map_size(route) == 5 <- route,
         true <-
           OverallsProtocol.uuid?(id) and is_integer(revision) and
             revision in 1..9_223_372_036_854_775_807,
         true <-
           OverallsProtocol.IngressName.valid_label?(label) and timestamp?(expiry) and
             digest?(fingerprint) do
      {:ok,
       %{
         id: id,
         revision: revision,
         label: label,
         expires_at: expiry,
         certificate_fingerprint: fingerprint
       }}
    else
      _ -> {:error, :invalid_message}
    end
  end

  def response(_), do: {:error, :invalid_message}

  defp digest?(value),
    do: is_binary(value) and byte_size(value) == 64 and Regex.match?(~r/\A[0-9a-f]{64}\z/, value)

  defp timestamp?(value) when is_binary(value) and byte_size(value) in 20..40 do
    case DateTime.from_iso8601(value) do
      {:ok, _, 0} -> true
      _ -> false
    end
  end

  defp timestamp?(_), do: false
end
