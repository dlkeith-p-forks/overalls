defmodule Lilly.VM.GuestTrust do
  @moduledoc "Boot-bound delivery of the host's public platform CA set over Firecracker vsock."
  alias Lilly.VM.Boot

  @port 1030
  @maximum_frame 1_048_576

  @type result :: {:ok, OverallsProtocol.uuid(), String.t()} | {:error, :trust_unconfirmed}

  # @cc [owner:ghuntley,label:security;recovery] guest-trust-boot-bound-receipt
  # Delivery MUST accept a bounded receipt only for this boot, nonce and exact
  # public CA set. The caller MUST verify confined current authority on both
  # sides of this exchange and persist the receipt before reporting running.
  @spec deliver(Path.t(), Boot.t(), [binary()], pos_integer()) :: result()
  def deliver(path, boot, roots, timeout) when is_integer(timeout) and timeout > 0 do
    nonce = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    digest = digest(roots)

    request = %{
      version: 1,
      placement_id: boot.placement_id,
      execution_epoch: boot.execution_epoch,
      boot_challenge: boot.boot_challenge,
      nonce: nonce,
      bundle_digest: digest,
      roots: roots
    }

    body = JSON.encode!(request)

    if byte_size(body) <= @maximum_frame do
      poll(path, boot, nonce, digest, body, System.monotonic_time(:millisecond) + timeout)
    else
      {:error, :trust_unconfirmed}
    end
  end

  def deliver(_, _, _, _), do: {:error, :trust_unconfirmed}

  @spec digest([binary()]) :: String.t()
  def digest(roots) do
    roots
    |> Enum.map(&:crypto.hash(:sha256, &1))
    |> Enum.sort()
    |> IO.iodata_to_binary()
    |> then(&:crypto.hash(:sha256, &1))
    |> Base.encode16(case: :lower)
  end

  defp poll(path, boot, nonce, digest, body, deadline) do
    if remaining(deadline) == 0 do
      {:error, :trust_unconfirmed}
    else
      case exchange(path, boot, nonce, digest, body, deadline) do
        {:ok, _boot_id, _digest} = receipt ->
          receipt

        _ ->
          Process.sleep(min(100, remaining(deadline)))
          poll(path, boot, nonce, digest, body, deadline)
      end
    end
  end

  defp exchange(path, boot, nonce, digest, body, deadline) do
    options = [:binary, active: false, packet: :line, packet_size: 64, send_timeout_close: true]

    case Lilly.Host.Sockets.connect_local(path, options, remaining(deadline)) do
      {:ok, socket} ->
        try do
          with :ok <- :inet.setopts(socket, send_timeout: remaining(deadline)),
               :ok <- :gen_tcp.send(socket, "CONNECT #{@port}\n"),
               {:ok, handshake} <- :gen_tcp.recv(socket, 0, remaining(deadline)),
               true <- Regex.match?(~r/\AOK [1-9][0-9]{0,9}\n\z/, handshake),
               :ok <- :inet.setopts(socket, packet: 4, packet_size: 1024),
               :ok <- :gen_tcp.send(socket, body),
               {:ok, response} <- :gen_tcp.recv(socket, 0, remaining(deadline)),
               {:ok, value} <- JSON.decode(response),
               true <- valid_receipt?(value, boot, nonce, digest),
               true <- remaining(deadline) > 0 do
            {:ok, value["boot_id"], digest}
          else
            _ -> {:error, :trust_unconfirmed}
          end
        after
          :gen_tcp.close(socket)
        end

      _ ->
        {:error, :trust_unconfirmed}
    end
  end

  defp valid_receipt?(value, boot, nonce, digest) when is_map(value) do
    map_size(value) == 8 and value["version"] == 1 and value["state"] == "installed" and
      value["placement_id"] == boot.placement_id and
      value["execution_epoch"] == boot.execution_epoch and
      value["boot_challenge"] == boot.boot_challenge and value["nonce"] == nonce and
      value["bundle_digest"] == digest and
      match?(
        {:ok, _},
        OverallsProtocol.Readiness.response(%{
          "version" => 1,
          "state" => "ready",
          "placement_id" => boot.placement_id,
          "execution_epoch" => boot.execution_epoch,
          "boot_challenge" => boot.boot_challenge,
          "boot_id" => value["boot_id"]
        })
      )
  end

  defp valid_receipt?(_, _, _, _), do: false
  defp remaining(deadline), do: max(deadline - System.monotonic_time(:millisecond), 0)
end
