defmodule OverallsAntithesis.Lilly.GuestRPC do
  @moduledoc "Bounded local control channel to the separately owned QEMU guest runner."

  @socket_env "OVERALLS_ANTITHESIS_GUEST_SOCKET"
  @maximum_request 4096
  @maximum_response 16_384
  @timeout 10_000

  @type request :: %{required(String.t()) => String.t() | pos_integer()}
  @type response :: %{required(String.t()) => term()}

  # @cc [owner:ghuntley,label:security;verification] guest-rpc-closed-local-frame
  # The bridge MUST send one bounded JSON line to an operator-selected local
  # socket and accept only one bounded JSON object line. An unavailable,
  # truncated, oversized or malformed response MUST NOT become an observation.
  @spec call(request()) :: {:ok, response()} | {:error, :guest_rpc_unavailable}
  def call(request) when is_map(request) do
    timeout = timeout_for(request)

    with path when is_binary(path) <- System.get_env(@socket_env),
         true <- valid_path?(path),
         encoded = JSON.encode!(request) <> "\n",
         true <- byte_size(encoded) <= @maximum_request,
         {:ok, socket} <- :gen_tcp.connect({:local, path}, 0, [:binary, active: false], timeout) do
      try do
        with :ok <- :gen_tcp.send(socket, encoded),
             {:ok, line} <-
               receive_line(socket, <<>>, System.monotonic_time(:millisecond) + timeout),
             {:ok, value} <- JSON.decode(line),
             true <- is_map(value) do
          {:ok, value}
        else
          _ -> {:error, :guest_rpc_unavailable}
        end
      after
        :gen_tcp.close(socket)
      end
    else
      _ -> {:error, :guest_rpc_unavailable}
    end
  end

  @spec receive_line(:gen_tcp.socket(), binary(), integer()) ::
          {:ok, binary()} | {:error, :guest_rpc_unavailable}
  defp receive_line(socket, collected, deadline) when byte_size(collected) < @maximum_response do
    case :gen_tcp.recv(socket, 0, max(deadline - System.monotonic_time(:millisecond), 0)) do
      {:ok, bytes} ->
        combined = collected <> bytes

        case :binary.match(combined, "\n") do
          {position, 1}
          when position < @maximum_response and byte_size(combined) == position + 1 ->
            {:ok, binary_part(combined, 0, position)}

          :nomatch when byte_size(combined) < @maximum_response ->
            receive_line(socket, combined, deadline)

          _ ->
            {:error, :guest_rpc_unavailable}
        end

      _ ->
        {:error, :guest_rpc_unavailable}
    end
  end

  defp receive_line(_socket, _collected, _timeout), do: {:error, :guest_rpc_unavailable}

  @spec timeout_for(request()) :: pos_integer()
  defp timeout_for(%{"operation" => "reconcile"}), do: 300_000
  defp timeout_for(%{"operation" => "stop"}), do: 45_000
  defp timeout_for(_), do: @timeout

  @spec valid_path?(String.t()) :: boolean()
  defp valid_path?(path),
    do:
      byte_size(path) in 1..107 and Path.type(path) == :absolute and
        Path.expand(path) == path and not String.contains?(path, [<<0>>, "\n", "\r"])
end
