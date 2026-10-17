defmodule Lilly.VM.Flush do
  @moduledoc "Best-effort guest sync request; lack of cooperation never prevents disk capture."
  alias Lilly.VM.Boot

  # @cc [owner:ghuntley,label:recovery;security] backup-flush-is-bounded-observation
  # request/3 MUST accept only a matching current-boot reply within one deadline.
  # It MUST NOT freeze, stop, start, or authorize a guest. Every transport/protocol
  # failure returns unconfirmed so callers can still snapshot its persistent disk.
  @spec request(Path.t(), Boot.t(), pos_integer()) :: :confirmed | :unconfirmed
  def request(path, boot, timeout \\ 10_000) do
    deadline = System.monotonic_time(:millisecond) + timeout
    nonce = Base.encode16(:crypto.strong_rand_bytes(32), case: :lower)
    expected = Boot.expectation(boot)

    request =
      Map.new(expected, fn {key, value} -> {Atom.to_string(key), value} end)
      |> Map.merge(%{"version" => 1, "operation" => "sync", "nonce" => nonce})

    options = [:binary, active: false, packet: :line, packet_size: 1024, send_timeout_close: true]

    case Lilly.Host.Sockets.connect_local(path, options, remaining(deadline)) do
      {:ok, socket} ->
        try do
          with :ok <- :inet.setopts(socket, send_timeout: remaining(deadline)),
               :ok <- :gen_tcp.send(socket, "CONNECT 1026\n"),
               {:ok, handshake} <- :gen_tcp.recv(socket, 0, remaining(deadline)),
               true <- Regex.match?(~r/\AOK [1-9][0-9]{0,9}\n\z/, handshake),
               :ok <- :gen_tcp.send(socket, JSON.encode!(request) <> "\n"),
               {:ok, bytes} <- :gen_tcp.recv(socket, 0, remaining(deadline)),
               {:ok, %{"state" => "flushed", "nonce" => ^nonce} = response} <- JSON.decode(bytes),
               response = response |> Map.delete("nonce") |> Map.put("state", "ready"),
               {:ok, _} <- OverallsProtocol.Readiness.verify(response, expected),
               true <- remaining(deadline) > 0,
               do: :confirmed,
               else: (_ -> :unconfirmed)
        after
          :gen_tcp.close(socket)
        end

      _ ->
        :unconfirmed
    end
  end

  @spec remaining(integer()) :: non_neg_integer()
  defp remaining(deadline), do: max(0, deadline - System.monotonic_time(:millisecond))
end
