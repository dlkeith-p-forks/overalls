defmodule Marshall.Compute.CapacityPolicy do
  @moduledoc "Trusted operator reconciliation of scheduler margins."
  alias Marshall.Compute.{Host, Ledger, StoragePool}

  # @cc [owner:ghuntley,label:capacity] operator-margins-host-serialized
  # Margin changes MUST serialize with admission under the host lock and use Ash
  # system actions. Applying zero scheduler margins MUST NOT change ownership,
  # native identities, logical enrollment bindings or existing reservations.
  @spec configure(String.t(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {:ok, :ok} | {:error, term()}
  def configure(host_id, cores, memory, disk) do
    Ledger.transaction(fn ->
      host = Ledger.lock!(Host, host_id)
      Ledger.update!(host, :configure, %{overhead_cores: cores, overhead_memory_bytes: memory})

      for pool <- Ledger.read!(StoragePool, host_id: host_id),
          do: Ledger.update!(pool, :configure_overhead, %{overhead_bytes: disk})

      :ok
    end)
  end
end
