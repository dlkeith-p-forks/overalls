defmodule OverallsProtocol.InceptionObservation do
  @moduledoc "Host DNS observations correlated with one child publication offer."

  # @cc [owner:ghuntley,label:security] inception-observation-closed-evidence
  # Evidence MUST name one prior request UUID and at most sixteen distinct
  # relative owners with exact bounded DNS-01 proof sets and remaining TTLs.
  # No peer address, absolute expiry or authority identity may be supplied.
  # Consumers MUST also verify the original boot/generation-bound offer and cap
  # expiry from that offer's creation, never from observation receipt.
  @spec validate(term()) :: {:ok, map() | nil} | {:error, :invalid_inception_observation}
  def validate(nil), do: {:ok, nil}

  def validate(%{"request_id" => request, "records" => records} = value)
      when map_size(value) == 2 and is_list(records) and length(records) <= 16 do
    if OverallsProtocol.uuid?(request) and Enum.all?(records, &record?/1) and
         Enum.uniq_by(records, & &1["label"]) == records,
       do: {:ok, value},
       else: {:error, :invalid_inception_observation}
  end

  def validate(_), do: {:error, :invalid_inception_observation}

  defp record?(%{"label" => label, "proofs" => proofs, "ttl_ms" => ttl} = record)
       when map_size(record) == 3 and is_list(proofs) and length(proofs) in 1..2 and
              is_integer(ttl) and ttl in 1..5000 do
    (label == "control" or OverallsProtocol.IngressName.valid_label?(label)) and
      Enum.all?(proofs, &proof?/1) and Enum.uniq(proofs) == proofs
  end

  defp record?(_), do: false

  defp proof?(value) when is_binary(value) and byte_size(value) == 43 do
    case Base.url_decode64(value, padding: false) do
      {:ok, bytes} when byte_size(bytes) == 32 ->
        Base.url_encode64(bytes, padding: false) == value

      _ ->
        false
    end
  end

  defp proof?(_), do: false
end
