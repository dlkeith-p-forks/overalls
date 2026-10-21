defmodule Lilly.Transfer.WorkerDiagnostics do
  @moduledoc "Bounded, payload-free failure transitions for transfer polling workers."
  require Lilly.Events

  @type component :: :source | :key | :receive | :clone
  @type reason :: :exception | :effect_task_exited | :unconfirmed

  # @cc [owner:ghuntley,label:observability;security] transfer-worker-failures-bounded
  # A worker MUST emit only a closed category on a changed failure, and one
  # recovery after a successful exchange. Raw exceptions, exit reasons and
  # control payloads MUST NOT enter diagnostics. No diagnostic changes pending
  # receipts, authority, retry timing or the effect-failure deduplication state.
  @spec failed(map(), component(), term()) :: map()
  def failed(state, component, failure) do
    reason = reason(failure)

    if Map.get(state, :worker_failure) != reason do
      Lilly.Events.emit("lilly.transfer_worker_unavailable",
        component: component,
        operation: state.mode,
        reason: reason
      )
    end

    Map.put(state, :worker_failure, reason)
  end

  @spec recovered(map(), component()) :: map()
  def recovered(state, component) do
    if Map.get(state, :worker_failure) do
      Lilly.Events.emit("lilly.transfer_worker_recovered",
        component: component,
        operation: state.mode
      )
    end

    Map.put(state, :worker_failure, nil)
  end

  @spec reason(term()) :: reason()
  defp reason({:error, :effect_task_exited}), do: :effect_task_exited

  defp reason({:error, reason})
       when reason in [:source_request_failed, :key_preparation_failed, :receive_failed],
       do: :exception

  defp reason(_), do: :unconfirmed
end
