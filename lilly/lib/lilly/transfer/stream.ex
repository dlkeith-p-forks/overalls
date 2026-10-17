defmodule Lilly.Transfer.Stream do
  @moduledoc """
  One guest dataset stream, run by lilly-hostd under this process's stream
  lease (ADR-0183). Lilly names the producer and consumer by typed fields;
  hostd derives every `zfs send`, `zfs receive`, `ssh` and `cmp` command line
  and runs them through `lilly-transfer-stream`.
  """
  alias Lilly.Host.{Hostd, Lock, PrivateFiles}

  @type producer :: Hostd.stream_producer()
  @type consumer :: Hostd.stream_consumer()
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
  # run/4 through run/6 MUST stream producer stdout directly into consumer
  # stdin without returning disk bytes or diagnostics to BEAM. Producer and
  # consumer are typed descriptors, never argv: hostd derives every command.
  # Caller MUST persist validated intent and verify current permit/reservation
  # before starting, and MUST NOT hold any lock: run acquires the stream
  # directory's lease itself and holds it until hostd reported the pipeline
  # killed and reaped. Explicit rates MUST be bounded integers; zero selects
  # an unthrottled local call, while production receivers require a positive
  # operator rate. The stable owner.lock MUST NOT be removed. Caller death
  # releases the lease, which makes hostd kill and reap the pipeline.
  # Success proves successful process exits and reaping only; it is not native
  # receive verification, activation authority or permission to delete source
  # data. Failure classes MUST remain closed local atoms, never raw exit
  # payloads or diagnostics. They identify observations, not causal attribution.

  # @cc [owner:ghuntley,label:protocol;capacity] stream-progress-is-not-receipt
  # An optional local progress recipient receives only monotonic transport-byte
  # counters, read from hostd's `<stream directory>/progress` counter and
  # tagged with this attempt's process identity; decreasing or malformed
  # values are ignored. Success still requires helper exit, not a counter.
  # Counters MUST NOT authorize adoption, reclamation or storage credit.
  @spec run(Path.t(), producer(), consumer(), pos_integer()) :: :ok | failure()
  @spec run(Path.t(), producer(), consumer(), pos_integer(), non_neg_integer()) ::
          :ok | failure()
  @spec run(Path.t(), producer(), consumer(), pos_integer(), non_neg_integer(), pid() | nil) ::
          :ok | failure()
  def run(directory, producer, consumer, timeout, rate \\ 0, progress \\ nil)

  def run(directory, producer, consumer, timeout, rate, progress)
      when timeout in 1000..86_400_000 and is_integer(rate) and rate in 0..1_073_741_824 and
             (is_nil(progress) or is_pid(progress)) do
    Overalls.Diagnostics.Tracing.with_span("lilly.transfer.stream", [], fn ->
      run_hosted(directory, producer, consumer, timeout, rate, progress)
    end)
  end

  def run(_, _, _, _, _, _), do: {:error, :invalid_stream}

  defp run_hosted(directory, producer, consumer, timeout, rate, progress) do
    with true <- is_nil(Lock.current()),
         :ok <- PrivateFiles.directory(directory),
         {:ok, lease} <- lease(directory) do
      reporter = report(Path.join(directory, "progress"), progress)

      outcome =
        try do
          Hostd.transfer_stream(lease.session, lease.id, producer, consumer, timeout, rate)
        after
          stop(reporter)
          Lock.release(lease)
        end

      result(outcome)
    else
      {:error, :stream_busy} = busy -> busy
      _ -> {:error, :invalid_stream}
    end
  end

  defp lease(directory) do
    case Lock.acquire(directory) do
      {:ok, lease} -> {:ok, lease}
      {:error, :host_already_owned} -> {:error, :stream_busy}
      _ -> {:error, :stream_helper_unavailable}
    end
  end

  # @cc [owner:ghuntley,label:recovery] stream-completion-requires-helper-exit
  # A receipt MUST require hostd's report that the helper exited, which it
  # sends only after the pipeline was killed and reaped. A lost session or
  # call timeout returns unconfirmed; callers MUST independently acquire the
  # same transfer lock before treating such work as quiescent.
  defp result({:exited, 0}), do: :ok
  defp result({:exited, 1}), do: {:error, :stream_failed}
  defp result({:exited, 2}), do: {:error, :stream_timeout}
  defp result({:exited, 3}), do: {:error, :stream_diagnostics_limit}
  defp result({:exited, 4}), do: {:error, :stream_revoked}
  defp result({:exited, 5}), do: {:error, :stream_producer_failed}
  defp result({:exited, 6}), do: {:error, :stream_consumer_failed}
  defp result({:exited, 7}), do: {:error, :stream_children_failed}
  defp result({:exited, 8}), do: {:error, :stream_pipe_failed}
  defp result({:error, :stream_timeout}), do: {:error, :stream_timeout}
  defp result({:error, :stream_revoked}), do: {:error, :stream_revoked}
  defp result({:error, :invalid_stream}), do: {:error, :invalid_stream}
  defp result({:error, :utility_unavailable}), do: {:error, :stream_helper_unavailable}
  defp result(_), do: {:error, :stream_unconfirmed}

  defp report(_path, nil), do: nil

  defp report(path, recipient) do
    owner = self()
    spawn_link(fn -> poll(path, recipient, owner, -1) end)
  end

  defp stop(nil), do: :ok

  defp stop(reporter) do
    ref = Process.monitor(reporter)
    send(reporter, {:stop, self()})

    receive do
      {:DOWN, ^ref, :process, _, _} -> :ok
    after
      5000 ->
        Process.unlink(reporter)
        Process.exit(reporter, :kill)
        :ok
    end
  end

  defp poll(path, recipient, owner, last) do
    last = forward(path, recipient, owner, last)

    receive do
      {:stop, ^owner} -> forward(path, recipient, owner, last)
    after
      1000 -> poll(path, recipient, owner, last)
    end
  end

  defp forward(path, recipient, owner, last) do
    case File.read(path) do
      {:ok, <<count::unsigned-big-64>>}
      when count > last and count <= 9_223_372_036_854_775_807 ->
        send(recipient, {:lilly_transfer_progress, owner, count})
        count

      _ ->
        last
    end
  end
end
