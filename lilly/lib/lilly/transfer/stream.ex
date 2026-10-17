defmodule Lilly.Transfer.Stream do
  @moduledoc "Native bounded-memory producer/receiver pipeline with separate transfer ownership."
  alias Lilly.Host.{Lock, PrivateFiles}
  @type command :: {Path.t(), [String.t()]}
  @type failure ::
          {:error,
           :invalid_stream
           | :stream_busy
           | :stream_failed
           | :stream_producer_failed
           | :stream_consumer_failed
           | :stream_children_failed
           | :stream_pipe_failed
           | :stream_timeout
           | :stream_diagnostics_limit
           | :stream_revoked
           | :stream_unconfirmed
           | :stream_helper_unavailable}

  # @cc [owner:ghuntley,label:security;recovery] native-stream-not-a-command-buffer
  # run/4 through run/6 MUST stream producer stdout directly into consumer stdin without returning
  # disk bytes or diagnostics to BEAM. Commands are trusted local absolute argv,
  # never shell text or peer-supplied executables. Caller MUST persist validated
  # intent and verify current permit/reservation before starting, and MUST NOT hold
  # the pool lock throughout transfer. Explicit rates MUST be bounded integers;
  # zero selects an unthrottled local utility call, while production receivers
  # require a positive operator rate. No ambient environment may select the rate.
  # The separate trusted transfer directory's
  # stable owner.lock MUST NOT be removed. Caller death revokes the native pipeline.
  # Success proves successful process exits and reaping only; it is not native
  # receive verification, activation authority or permission to delete source data.
  # Child/pipe failure classes MUST remain closed local atoms, never raw exit
  # payloads or diagnostics. They identify observations, not causal attribution.

  # @cc [owner:ghuntley,label:protocol;capacity] stream-progress-is-not-receipt
  # An optional local progress recipient receives only monotonic transport-byte
  # counters tagged with this attempt's process identity. Native frames MUST be
  # bounded and parsed after the exact lock acknowledgement; malformed, decreasing
  # or oversized values fail. Success still requires helper exit, not a counter.
  # Counters MUST NOT authorize adoption, reclamation or storage credit.
  @spec run(Path.t(), command(), command(), pos_integer()) :: :ok | failure()
  @spec run(Path.t(), command(), command(), pos_integer(), non_neg_integer()) :: :ok | failure()
  @spec run(Path.t(), command(), command(), pos_integer(), non_neg_integer(), pid() | nil) ::
          :ok | failure()
  def run(directory, producer, consumer, timeout, rate \\ 0, progress \\ nil)

  def run(directory, producer, consumer, timeout, rate, progress)
      when timeout in 1000..86_400_000 and is_integer(rate) and rate in 0..1_073_741_824 do
    Overalls.Diagnostics.Tracing.with_span("lilly.transfer.stream", [], fn ->
      run_native(directory, producer, consumer, timeout, rate, progress)
    end)
  end

  def run(_, _, _, _, _, _), do: {:error, :invalid_stream}

  @spec run_native(Path.t(), command(), command(), pos_integer(), non_neg_integer(), pid() | nil) ::
          :ok | failure()
  defp run_native(directory, producer, consumer, timeout, rate, progress) do
    with true <- is_nil(Lock.current()) and (is_nil(progress) or is_pid(progress)),
         {:ok, producer} <- argv(producer),
         {:ok, consumer} <- argv(consumer),
         true <- Enum.sum(Enum.map(producer ++ consumer, &(byte_size(&1) + 1))) <= 65_536,
         :ok <- PrivateFiles.directory(directory),
         helper when is_binary(helper) <- System.find_executable("lilly-transfer-stream") do
      port =
        Port.open({:spawn_executable, helper}, [
          :binary,
          :exit_status,
          :stderr_to_stdout,
          env: [
            {~c"LILLY_TRANSFER_BYTES_PER_SECOND", Integer.to_charlist(rate)},
            {~c"LILLY_TRANSFER_PROGRESS", if(is_nil(progress), do: ~c"0", else: ~c"1")}
          ],
          args:
            [
              Path.join(directory, "owner.lock"),
              Integer.to_string(timeout),
              Integer.to_string(length(producer))
            ] ++ producer ++ consumer
        ])

      nonce = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false) <> "\n"

      try do
        Port.command(port, nonce)
      rescue
        ArgumentError -> :ok
      end

      await(
        port,
        nonce,
        %{ack: false, buffer: "", count: 0, seen: false},
        System.monotonic_time(:millisecond) + timeout + 2000,
        progress
      )
    else
      _ -> {:error, :invalid_stream}
    end
  rescue
    _ in [ArgumentError, ErlangError] -> {:error, :stream_helper_unavailable}
  end

  defp argv({executable, arguments}) when is_binary(executable) and is_list(arguments) do
    all = [executable | arguments]

    if Path.type(executable) == :absolute and length(all) <= 128 and
         Enum.all?(all, &(is_binary(&1) and not String.contains?(&1, "\0"))),
       do: {:ok, all},
       else: :error
  end

  defp argv(_), do: :error

  # @cc [owner:ghuntley,label:recovery] stream-completion-requires-helper-exit
  # A receipt MUST require the exact lock acknowledgement followed by native exit.
  # Timeout or malformed stdout closes the port and returns unconfirmed; callers
  # MUST independently acquire the same transfer lock before treating such work as
  # quiescent. Closing a port alone MUST NOT release reservations or stream slots.
  defp await(port, nonce, state, deadline, progress) do
    if System.monotonic_time(:millisecond) >= deadline do
      unconfirmed(port)
    else
      receive do
        {^port, {:data, bytes}} when byte_size(state.buffer) + byte_size(bytes) <= 4096 ->
          case consume(%{state | buffer: state.buffer <> bytes}, nonce, progress) do
            {:ok, next} -> await(port, nonce, next, deadline, progress)
            :error -> unconfirmed(port)
          end

        {^port, {:data, _}} ->
          unconfirmed(port)

        {^port, {:exit_status, status}} ->
          complete =
            state.ack and state.buffer == "" and
              (status != 0 or is_nil(progress) or state.seen)

          result(status, complete)
      after
        max(0, deadline - System.monotonic_time(:millisecond)) -> unconfirmed(port)
      end
    end
  end

  defp consume(%{ack: false, buffer: buffer} = state, nonce, progress) do
    size = byte_size(nonce)

    if byte_size(buffer) < size do
      if String.starts_with?(nonce, buffer), do: {:ok, state}, else: :error
    else
      case buffer do
        <<^nonce::binary-size(^size), rest::binary>> ->
          consume(%{state | ack: true, buffer: rest}, nonce, progress)

        _ ->
          :error
      end
    end
  end

  defp consume(%{buffer: ""} = state, _, _), do: {:ok, state}

  defp consume(%{buffer: buffer} = state, nonce, progress) when is_pid(progress) do
    case buffer do
      <<?P, count::unsigned-big-64, rest::binary>>
      when count >= state.count and count <= 9_223_372_036_854_775_807 ->
        send(progress, {:lilly_transfer_progress, self(), count})
        consume(%{state | buffer: rest, count: count, seen: true}, nonce, progress)

      <<?P, _::binary>> when byte_size(buffer) < 9 ->
        {:ok, state}

      _ ->
        :error
    end
  end

  defp consume(_, _, _), do: :error

  defp result(0, true), do: :ok
  defp result(1, true), do: {:error, :stream_failed}
  defp result(2, true), do: {:error, :stream_timeout}
  defp result(3, true), do: {:error, :stream_diagnostics_limit}
  defp result(4, true), do: {:error, :stream_revoked}
  defp result(5, true), do: {:error, :stream_producer_failed}
  defp result(6, true), do: {:error, :stream_consumer_failed}
  defp result(7, true), do: {:error, :stream_children_failed}
  defp result(8, true), do: {:error, :stream_pipe_failed}
  defp result(73, false), do: {:error, :stream_busy}
  defp result(_, _), do: {:error, :stream_unconfirmed}

  defp unconfirmed(port) do
    if Port.info(port), do: Port.close(port)
    {:error, :stream_unconfirmed}
  end
end
