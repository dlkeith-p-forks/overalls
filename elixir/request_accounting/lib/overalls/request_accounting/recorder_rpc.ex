defmodule Overalls.RequestAccounting.RecorderRPC do
  @moduledoc "Bounded version-one Unix RPC to the independently supervised Rust recorder."

  @max_counter 9_223_372_036_854_775_807

  @type command ::
          %{op: :hello | :admit | :gap}
          | %{
              op: :finish,
              id: pos_integer(),
              outcome: :success | :failure | :exclude,
              duration_us: non_neg_integer()
            }
  @type reply :: :ok | {:admitted, pos_integer()} | {:error, :unavailable | :refused}

  # @cc [owner:ghuntley,label:security;reliability] recorder-rpc-closed-bounded
  # RPC MUST bound frames and operation time, validate the closed reply schema,
  # and return only closed failures. Unknown acknowledgments MUST NOT count as
  # durable admissions or completions. Invalid caller input MUST return a closed
  # failure rather than raising. No peer-controlled atom may be created.
  @spec call(binary(), command()) :: reply()
  def call(path, command) do
    if valid_path?(path) and valid_command?(command) do
      options = [:binary, {:active, false}, {:packet, 4}, {:packet_size, 512}]

      case :gen_tcp.connect({:local, String.to_charlist(path)}, 0, options, 1_000) do
        {:ok, socket} ->
          result = exchange(socket, command)
          :gen_tcp.close(socket)
          result

        _ ->
          {:error, :unavailable}
      end
    else
      {:error, :unavailable}
    end
  end

  @spec exchange(:gen_tcp.socket(), command()) :: reply()
  defp exchange(socket, command) do
    body = JSON.encode!(%{version: 1, command: command})

    with true <- byte_size(body) <= 512,
         :ok <- :gen_tcp.send(socket, body),
         {:ok, bytes} <- :gen_tcp.recv(socket, 0, 1_000) do
      decode(bytes)
    else
      _ -> {:error, :unavailable}
    end
  end

  @spec decode(binary()) :: reply()
  def decode(bytes) when byte_size(bytes) <= 512 do
    try do
      case JSON.decode(bytes) do
        {:ok, %{"status" => "ok"} = reply} when map_size(reply) == 1 ->
          :ok

        {:ok, %{"status" => "admitted", "id" => id} = reply}
        when map_size(reply) == 2 and is_integer(id) and id in 1..@max_counter ->
          {:admitted, id}

        {:ok, %{"status" => "refused", "reason" => reason} = reply}
        when map_size(reply) == 2 and
               reason in ["version", "schema", "producer", "capacity", "accounting", "storage"] ->
          {:error, :refused}

        _ ->
          {:error, :unavailable}
      end
    rescue
      _ -> {:error, :unavailable}
    end
  end

  def decode(_bytes), do: {:error, :unavailable}

  @spec valid_path?(term()) :: boolean()
  defp valid_path?(path) when is_binary(path),
    do:
      byte_size(path) > 1 and String.starts_with?(path, "/") and String.valid?(path) and
        not String.contains?(path, <<0>>)

  defp valid_path?(_path), do: false

  @spec valid_command?(term()) :: boolean()
  defp valid_command?(%{op: op} = command) when op in [:hello, :admit, :gap],
    do: Map.keys(command) == [:op]

  defp valid_command?(
         %{op: :finish, id: id, outcome: outcome, duration_us: duration_us} = command
       ) do
    Enum.sort(Map.keys(command)) == [:duration_us, :id, :op, :outcome] and
      is_integer(id) and id in 1..@max_counter and outcome in [:success, :failure, :exclude] and
      is_integer(duration_us) and duration_us in 0..@max_counter
  end

  defp valid_command?(_command), do: false
end
