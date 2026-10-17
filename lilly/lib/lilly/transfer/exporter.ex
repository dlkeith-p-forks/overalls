defmodule Lilly.Transfer.Exporter do
  @moduledoc "Native sender custody for an isolated export process with an authenticated stdout."
  require Lilly.Events
  alias Lilly.Host.{Lock, PrivateFiles}
  @opaque t :: %{port: port()}
  @type failure :: {:error, atom()}

  # @cc [owner:ghuntley,label:security;recovery] exporter-start-registers-under-authority-lock
  # start/3 requires an isolated export process whose inherited stdout is the
  # authenticated transport, never the Lilly daemon's log stream. Its caller MUST
  # hold the permit mutation lock, validate current authority and native ownership,
  # and supply trusted absolute sender argv. It returns only after native transfer
  # ownership and sender registration; disk bytes never pass through BEAM. The
  # caller MUST release pool/mutation locks before wait/2. Caller death closes the
  # private control channel; the native helper retains its lock through reaping.
  @spec start(Path.t(), Lilly.Transfer.Stream.command(), pos_integer()) :: {:ok, t()} | failure()
  def start(directory, {executable, args}, lease)
      when is_binary(executable) and is_list(args) and lease in 1..300_000 do
    with true <- Path.type(executable) == :absolute and length(args) < 128,
         true <-
           Enum.all?([executable | args], &(is_binary(&1) and not String.contains?(&1, "\0"))),
         true <- Enum.sum(Enum.map([executable | args], &(byte_size(&1) + 1))) <= 65_536,
         :ok <- PrivateFiles.directory(directory),
         helper when is_binary(helper) <- System.find_executable("lilly-source-export") do
      port =
        Port.open({:spawn_executable, helper}, [
          :binary,
          :exit_status,
          :nouse_stdio,
          args: [Path.join(directory, "owner.lock"), Integer.to_string(lease), executable | args]
        ])

      nonce = Base.url_encode64(:crypto.strong_rand_bytes(16), padding: false) <> "\n"
      send_control(port, nonce)
      registered(port, nonce, "", System.monotonic_time(:millisecond) + 2000)
    else
      _ -> {:error, :invalid_exporter}
    end
  rescue
    _ in [ArgumentError, ErlangError] -> {:error, :exporter_unavailable}
  end

  def start(_, _, _), do: {:error, :invalid_exporter}

  # @cc [owner:ghuntley,label:security;recovery] exporter-wait-is-lease-supervision
  # wait/2 MUST run without pool or permit mutation locks and query trusted lease
  # authority at least every 250ms while scheduled. Only a newly verified renewal
  # may extend the native deadline. Exceptions, revocation or invalid responses
  # MUST cancel the sender. Success requires native reaping, not port closure.
  # Unconfirmed results require independent acquisition of the stable transfer
  # lock before any caller acknowledges quiescence or releases resources.
  @spec wait(t(), (-> :ok | :revoke | {:renew, pos_integer()})) :: :ok | failure()
  def wait(%{port: port}, refresh) when is_function(refresh, 0) do
    wait(%{port: port}, nil, fn state -> {refresh.(), state} end)
  end

  @spec wait(t(), state, (state -> {:ok | :revoke | {:renew, pos_integer()}, state})) ::
          :ok | failure()
        when state: term()
  def wait(%{port: port}, state, refresh) when is_function(refresh, 1) do
    if is_nil(Lock.current()) do
      await(port, state, refresh)
    else
      cancel(%{port: port})
      {:error, :exporter_lock_held}
    end
  end

  @spec cancel(t()) :: failure()
  def cancel(%{port: port}) do
    send_control(port, "X\n")
    stopped(port, System.monotonic_time(:millisecond) + 2000)
  end

  defp registered(port, nonce, bytes, deadline) do
    receive do
      {^port, {:data, more}} when byte_size(bytes) + byte_size(more) <= byte_size(nonce) ->
        case bytes <> more do
          ^nonce -> {:ok, %{port: port}}
          prefix -> registered(port, nonce, prefix, deadline)
        end

      {^port, {:exit_status, 73}} ->
        failed(:exporter_busy)

      {^port, {:exit_status, _}} ->
        failed(:exporter_unconfirmed)

      {^port, {:data, _}} ->
        unconfirmed(port)
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> unconfirmed(port)
    end
  end

  defp await(port, state, refresh) do
    receive do
      {^port, {:exit_status, status}} -> result(status)
      {^port, {:data, _}} -> unconfirmed(port)
    after
      250 ->
        case authority(refresh, state) do
          {:ok, state} ->
            await(port, state, refresh)

          {{:renew, ttl}, state} when ttl in 1..300_000 ->
            send_control(port, "L#{ttl}\n")
            await(port, state, refresh)

          _ ->
            cancel(%{port: port})
        end
    end
  end

  defp authority(refresh, state) do
    refresh.(state)
  rescue
    _ -> :revoke
  catch
    _, _ -> :revoke
  end

  defp stopped(port, deadline) do
    receive do
      {^port, {:exit_status, _}} -> {:error, :exporter_revoked}
      {^port, {:data, _}} -> stopped(port, deadline)
    after
      max(0, deadline - System.monotonic_time(:millisecond)) -> unconfirmed(port)
    end
  end

  defp send_control(port, bytes) do
    Port.command(port, bytes)
  rescue
    ArgumentError -> false
  end

  # @cc [owner:ghuntley,label:security;observability] exporter-custody-failures-closed
  # Sender custody failures MUST report only the closed reason atom; control
  # protocol bytes, argv, exit statuses and native output MUST NOT be logged.
  # A commanded revocation confirmed by exit is an expected outcome and MUST
  # NOT emit a failure event. Each custody failure occurs at most once per
  # sender, so no additional deduplication is required.
  defp result(0), do: :ok
  defp result(1), do: failed(:exporter_failed)
  defp result(2), do: failed(:exporter_expired)
  defp result(3), do: failed(:exporter_diagnostics_limit)
  defp result(4), do: {:error, :exporter_revoked}
  defp result(_), do: failed(:exporter_unconfirmed)

  defp failed(reason) do
    Lilly.Events.emit("lilly.transfer_export_failed", reason: reason)
    {:error, reason}
  end

  defp unconfirmed(port) do
    if Port.info(port), do: Port.close(port)
    failed(:exporter_unconfirmed)
  end
end
