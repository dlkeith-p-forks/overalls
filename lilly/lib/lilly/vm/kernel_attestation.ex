defmodule Lilly.VM.KernelAttestation do
  @moduledoc "Bounded native guest kernel attestation over the jail-local vsock."
  alias OverallsProtocol.KernelAttestation, as: Protocol

  @port 1098
  @default_timeout 120_000
  @maximum_timeout 2_400_000
  @maximum_frame 512

  @type expectation :: Protocol.expectation()
  @type result ::
          {:ok, OverallsProtocol.uuid()}
          | {:error, :kernel_attestation_timeout | :invalid_kernel_attestation_request}

  # @cc [owner:ghuntley,label:security;recovery] native-kernel-probe-bounded
  # verify/3 MUST use only the caller-owned jail-local socket, a fixed native
  # probe port and one monotonic deadline. It MUST return success only when the
  # guest response matches the current boot, native OS and manifest kernel
  # digest; malformed, stale and oversized frames remain retryable evidence.
  @spec verify(Path.t(), expectation(), pos_integer()) :: result()
  def verify(path, expected, timeout \\ @default_timeout) do
    if valid_request?(path, expected, timeout) do
      poll(path, expected, System.monotonic_time(:millisecond) + timeout)
    else
      {:error, :invalid_kernel_attestation_request}
    end
  end

  defp valid_request?(path, expected, timeout) do
    is_binary(path) and byte_size(path) in 1..107 and String.valid?(path) and
      String.starts_with?(path, "/") and not String.contains?(path, <<0>>) and
      is_integer(timeout) and timeout in 1..@maximum_timeout and valid_expectation?(expected)
  end

  defp valid_expectation?(
         %{
           placement_id: placement,
           execution_epoch: epoch,
           boot_challenge: challenge,
           os: os,
           kernel_sha256: digest
         } = value
       )
       when map_size(value) == 5 do
    match?(
      {:ok, _},
      Protocol.response(%{
        "version" => 1,
        "state" => "attested",
        "os" => wire_os(os),
        "placement_id" => placement,
        "execution_epoch" => epoch,
        "boot_challenge" => challenge,
        "boot_id" => placement,
        "kernel_sha256" => digest
      })
    )
  end

  defp valid_expectation?(_), do: false

  defp poll(path, expected, deadline) do
    if remaining(deadline) == 0 do
      {:error, :kernel_attestation_timeout}
    else
      case probe(path, expected, deadline) do
        {:ok, boot_id} ->
          {:ok, boot_id}

        :not_attested ->
          Process.sleep(min(100, remaining(deadline)))
          poll(path, expected, deadline)
      end
    end
  end

  defp probe(path, expected, deadline) do
    options = [
      :binary,
      active: false,
      packet: :line,
      packet_size: @maximum_frame,
      send_timeout_close: true
    ]

    case Lilly.Host.Sockets.connect_local(path, options, remaining(deadline)) do
      {:ok, socket} ->
        try do
          with :ok <- :inet.setopts(socket, send_timeout: remaining(deadline)),
               :ok <- :gen_tcp.send(socket, "CONNECT #{@port}\n"),
               {:ok, handshake} <- :gen_tcp.recv(socket, 0, remaining(deadline)),
               true <- handshake?(handshake),
               {:ok, body} <- :gen_tcp.recv(socket, 0, remaining(deadline)),
               true <- byte_size(body) <= @maximum_frame and String.ends_with?(body, "\n"),
               {:ok, value} <- JSON.decode(body),
               {:ok, boot_id} <- Protocol.verify(value, expected),
               true <- remaining(deadline) > 0 do
            {:ok, boot_id}
          else
            _ -> :not_attested
          end
        after
          :gen_tcp.close(socket)
        end

      {:error, _} ->
        :not_attested
    end
  end

  defp handshake?(<<"OK ", suffix::binary>>) when byte_size(suffix) <= 11 do
    case Integer.parse(suffix) do
      {port, "\n"} when port in 1..4_294_967_295 -> suffix == Integer.to_string(port) <> "\n"
      _ -> false
    end
  end

  defp handshake?(_), do: false

  defp wire_os(:freebsd), do: "freebsd"
  defp wire_os(:illumos), do: "illumos"
  defp wire_os(_), do: :invalid

  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
