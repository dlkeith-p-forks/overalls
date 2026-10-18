defmodule Audi.Wake do
  @moduledoc "Bounded connection wait with renewable authorization and no execution authority."
  @type receipt :: OverallsProtocol.IngressWake.receipt()
  @type result :: {:ok, map()} | {:pending, receipt()} | {:error, atom()}
  @type guard :: %{timer: :timer.tref(), deadline: integer(), vm_id: String.t()}

  # @cc [owner:ghuntley,label:security;recovery] audi-wait-renewable-authority
  # Waiting MUST have bounded concurrency and an independent request-start
  # authorization deadline. Every poll repeats fresh authority. Capacity waits
  # MAY continue while authority renews; denial or expiry MUST end the owner.
  # Waiting MUST NOT read a request body, open a guest socket or replay bytes.
  @spec await((-> result())) :: {:ok, map()} | {:error, atom()}
  def await(request) do
    started = now()

    case request.() do
      {:pending, receipt} ->
        with :ok <- Audi.Wake.Waiters.acquire() do
          try do
            cancel_setup()

            case arm(nil, receipt, started) do
              {:ok, guard} -> wait(request, receipt.retry_after_ms, guard)
              error -> error
            end
          after
            Audi.Wake.Waiters.release()
          end
        end

      result ->
        result
    end
  end

  @spec wait((-> result()), pos_integer(), guard()) :: {:ok, map()} | {:error, atom()}
  defp wait(request, delay, guard) do
    receive do
    after
      min(delay, max(guard.deadline - now(), 0)) -> :ok
    end

    if now() >= guard.deadline do
      finish(guard, {:error, :expired_response})
    else
      started = now()

      case request.() do
        {:pending, receipt} ->
          case arm(guard, receipt, started) do
            {:ok, next} -> wait(request, receipt.retry_after_ms, next)
            error -> finish(guard, error)
          end

        {:ok, _} = ready ->
          result = if now() < guard.deadline, do: ready, else: {:error, :expired_response}
          finish(guard, result)

        {:error, reason} = error ->
          if reason in [:transport_error, :http_error] and now() < guard.deadline,
            do: wait(request, 1000, guard),
            else: finish(guard, error)
      end
    end
  end

  @spec finish(guard(), {:ok, map()} | {:error, atom()}) :: {:ok, map()} | {:error, atom()}
  defp finish(guard, result) do
    :timer.cancel(guard.timer)
    result
  end

  @spec arm(guard() | nil, receipt(), integer()) ::
          {:ok, guard()} | {:error, :expired_response | :binding_mismatch}
  defp arm(previous, receipt, started) do
    cond do
      previous && previous.vm_id != receipt.vm_id ->
        {:error, :binding_mismatch}

      previous && now() >= previous.deadline ->
        {:error, :expired_response}

      started + receipt.ttl <= now() ->
        {:error, :expired_response}

      true ->
        deadline = started + receipt.ttl
        {:ok, timer} = :timer.exit_after(max(deadline - now(), 1), self(), :kill)
        if previous, do: :timer.cancel(previous.timer)
        {:ok, %{timer: timer, deadline: deadline, vm_id: receipt.vm_id}}
    end
  end

  @spec cancel_setup() :: :ok
  defp cancel_setup do
    case Process.delete({__MODULE__, :setup_timer}) do
      nil ->
        :ok

      timer ->
        :timer.cancel(timer)
        :ok
    end
  end

  @spec now() :: integer()
  defp now, do: System.monotonic_time(:millisecond)
end
