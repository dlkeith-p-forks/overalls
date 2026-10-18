defmodule OverallsProtocol.IngressWake do
  @moduledoc "Bounded non-execution receipts while an authorized connection waits for a VM."
  @type receipt :: %{vm_id: String.t(), ttl: pos_integer(), retry_after_ms: pos_integer()}

  # @cc [owner:ghuntley,label:security;protocol] ingress-wake-receipt-is-not-authority
  # A pending receipt MUST contain only a VM identity, bounded freshness and retry
  # interval. It MUST NOT contain a placement, socket address or stream authority.
  @spec decode(term()) :: {:ok, receipt()} | {:error, :invalid_message}
  def decode(%{"version" => 1, "pending" => pending} = envelope)
      when map_size(envelope) == 2 do
    with %{"vm_id" => vm, "ttl" => ttl, "retry_after_ms" => retry} when map_size(pending) == 3 <-
           pending,
         true <- OverallsProtocol.uuid?(vm),
         true <- is_integer(ttl) and ttl in 1..30_000,
         true <- is_integer(retry) and retry in 100..5000 and retry < ttl do
      {:ok, %{vm_id: vm, ttl: ttl, retry_after_ms: retry}}
    else
      _ -> {:error, :invalid_message}
    end
  end

  def decode(_), do: {:error, :invalid_message}
end
