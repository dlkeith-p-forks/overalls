defmodule Lilly.VM.Readiness do
  @moduledoc "Bounded Firecracker vsock readiness observation, separate from launch authority."
  alias OverallsProtocol.Readiness, as: Protocol
  @default_timeout 120_000
  @maximum_timeout 2_400_000

  @doc "Poll a caller-owned jail's vsock path for the persisted current boot expectation."
  # @cc [owner:ghuntley,label:recovery;security] readiness-deadline-and-boot-binding
  # wait/3 MUST bound the whole poll by one monotonic deadline and reject stale boot
  # identity, malformed/oversized replies and failed Firecracker handshakes. A valid
  # connected probe MUST be allowed the remaining deadline rather than an independent
  # shorter timeout that can repeatedly discard slow but healthy guest responses. The caller
  # MUST select a locally owned current VMM socket and recheck execution authority before
  # using success. This function MUST NOT authorize activation or source reclamation.
  # The request MUST remain bounded to forty minutes at most.
  @spec wait(Path.t(), Protocol.expectation(), pos_integer()) ::
          {:ok, OverallsProtocol.uuid()}
          | {:error, :readiness_timeout | :invalid_readiness_request}
  def wait(path, expected, timeout \\ @default_timeout) do
    if valid_request?(path, expected, timeout) do
      poll(path, expected, now() + timeout)
    else
      {:error, :invalid_readiness_request}
    end
  end

  defp valid_request?(path, expected, timeout) do
    is_binary(path) and byte_size(path) in 1..107 and String.valid?(path) and
      String.starts_with?(path, "/") and
      not String.contains?(path, <<0>>) and is_integer(timeout) and
      timeout in 1..@maximum_timeout and valid_expectation?(expected)
  end

  defp valid_expectation?(
         %{placement_id: placement, execution_epoch: epoch, boot_challenge: nonce} = value
       )
       when map_size(value) == 3 do
    message = %{
      "version" => 1,
      "state" => "ready",
      "placement_id" => placement,
      "execution_epoch" => epoch,
      "boot_challenge" => nonce,
      "boot_id" => placement
    }

    match?({:ok, _}, Protocol.response(message))
  end

  defp valid_expectation?(_), do: false

  defp poll(path, expected, deadline) do
    if remaining(deadline) == 0 do
      {:error, :readiness_timeout}
    else
      case probe(path, expected, deadline) do
        {:ok, boot} ->
          if remaining(deadline) > 0, do: {:ok, boot}, else: {:error, :readiness_timeout}

        :not_ready ->
          Process.sleep(min(100, remaining(deadline)))
          poll(path, expected, deadline)
      end
    end
  end

  defp probe(path, expected, deadline) do
    options = [:binary, active: false, packet: :line, packet_size: 512, send_timeout_close: true]

    case Lilly.Host.Sockets.connect_local(path, options, remaining(deadline)) do
      {:ok, socket} ->
        try do
          with :ok <- :inet.setopts(socket, send_timeout: remaining(deadline)),
               :ok <- :gen_tcp.send(socket, "CONNECT 1024\n"),
               {:ok, handshake} <- :gen_tcp.recv(socket, 0, remaining(deadline)),
               true <- handshake?(handshake),
               {:ok, body} <- :gen_tcp.recv(socket, 0, remaining(deadline)),
               true <- byte_size(body) <= 512 and String.ends_with?(body, "\n"),
               {:ok, message} <- JSON.decode(body),
               {:ok, boot} <- Protocol.verify(message, expected) do
            {:ok, boot}
          else
            _ -> :not_ready
          end
        after
          :gen_tcp.close(socket)
        end

      {:error, _} ->
        :not_ready
    end
  end

  defp handshake?("OK " <> suffix) when byte_size(suffix) <= 11 do
    case Integer.parse(suffix) do
      {port, "\n"} when port in 1..4_294_967_295 -> suffix == Integer.to_string(port) <> "\n"
      _ -> false
    end
  end

  defp handshake?(_), do: false
  defp remaining(deadline), do: max(deadline - now(), 0)
  defp now, do: System.monotonic_time(:millisecond)
end
