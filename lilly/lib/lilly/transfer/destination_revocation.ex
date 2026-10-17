defmodule Lilly.Transfer.DestinationRevocation do
  @moduledoc "Early key fencing and confirmed local transfer quiescence after cancellation or committed handoff."
  alias OverallsProtocol.RelocationDestinationRevocation, as: Wire
  alias Lilly.Host.Lock
  alias Lilly.Transfer.Key

  # @cc [owner:ghuntley,label:security;recovery] destination-fence-before-quiescence
  # execute/3 requires authenticated cancellation or committed-handoff authority and no held host lock.
  # It MUST permanently retire the destination key before attempting receive and
  # stream locks, including cancellation before key generation. Busy work MUST
  # retain that fence and return unconfirmed. Success requires both locks and a
  # live lease; it MUST NOT claim source revocation, VM/disk deletion or resource
  # release. Existing bounded native work may finish before a retry confirms
  # quiescence; key deletion alone is never a quiescence receipt.
  @spec execute(Path.t(), String.t(), Wire.command()) :: {:ok, Wire.result()} | {:error, atom()}
  def execute(root, host, command) do
    with true <- is_nil(Lock.current()),
         {:ok, ^command} <- Wire.command(Wire.encode(command)),
         true <- command.host_id == host,
         :ok <- lease(command),
         :ok <- Key.retire(root, host, command.id, command.placement_id),
         directory = Path.join([root, "transfers", command.id]),
         :ok <-
           owned(Path.join(directory, "receive"), fn ->
             owned(Path.join(directory, "stream"), fn ->
               with :ok <- lease(command),
                    do: Key.retire(root, host, command.id, command.placement_id)
             end)
           end),
         do: {:ok, Map.take(command, [:id, :placement_id, :execution_epoch])},
         else: (_ -> failure())
  end

  defp owned(directory, fun) do
    with {:ok, lock} <- Lock.acquire(directory) do
      try do
        result = fun.()
        with :ok <- Lock.release(lock), do: result
      after
        if Lock.held?(lock), do: Lock.release(lock)
      end
    end
  end

  defp lease(command),
    do: if((command.expires_at - System.system_time(:second)) in 1..300, do: :ok, else: failure())

  defp failure, do: {:error, :destination_revocation_unconfirmed}
end
