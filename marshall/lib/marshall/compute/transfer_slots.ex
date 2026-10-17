defmodule Marshall.Compute.TransferSlots do
  @moduledoc "Pair allocation inside the relocation coordinator's host-locked transaction."
  alias Marshall.Compute.{Ledger, Relocation, TransferSlot}

  # @cc [owner:ghuntley,label:concurrency] transfer-pair-all-or-nothing
  # occupy_locked!/1 MUST be called with both endpoint host locks already held in
  # UUID order, inside the transaction reserving the relocation's capacity. It
  # MUST reserve both roles or roll back the transaction. Exact retries reuse
  # occupied slots; another relocation or a previously released slot cannot be
  # silently reclaimed. Neither insertion authorizes a stream or VM launch.
  @spec occupy_locked!(Relocation.t()) :: [TransferSlot.t()]
  def occupy_locked!(relocation) do
    unless Marshall.Repo.in_transaction?(), do: raise(ArgumentError, "transaction required")
    [current] = Ledger.read!(Relocation, id: relocation.id)
    if current.finished_at != nil, do: Ledger.rollback(:relocation_finished)

    [
      {current.source_host_id, :source_relocation_id},
      {current.destination_host_id, :destination_relocation_id}
    ]
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map(fn {host_id, role} ->
      case Ledger.read!(TransferSlot, [{role, relocation.id}]) do
        [%{host_id: ^host_id, released_at: nil} = slot] ->
          slot

        [] ->
          if Ledger.read!(TransferSlot, host_id: host_id, released_at: [is_nil: true]) != [],
            do: Ledger.rollback(:transfer_busy)

          Ledger.create!(TransferSlot, :occupy, %{role => relocation.id, :host_id => host_id})

        _ ->
          Ledger.rollback(:transfer_slot_released)
      end
    end)
  end
end
