defmodule Audi.HTTP.WebSocketFrame do
  @moduledoc "Bounded RFC6455 client frames for the local guest WebSocket leg."
  @maximum 1_048_576
  @spec maximum() :: pos_integer()
  def maximum, do: @maximum

  # @cc [owner:ghuntley,label:security] audi-websocket-frame-bounds
  # Guest server frames MUST be unmasked, RSV-free and canonically length encoded.
  # Frames/messages MUST be bounded before buffering. Client frames MUST receive
  # a fresh unpredictable mask; no guest payload may reach diagnostics.
  @spec decode(binary()) :: {:ok, map(), binary()} | :more | :error
  def decode(<<fin::1, 0::3, opcode::4, 0::1, length::7, rest::binary>>)
      when opcode in [0, 1, 2, 8, 9, 10] do
    case size(length, rest) do
      {:ok, size, rest} when size <= @maximum ->
        cond do
          opcode >= 8 and (fin != 1 or size > 125 or (opcode == 8 and size == 1)) ->
            :error

          byte_size(rest) < size ->
            :more

          true ->
            <<payload::binary-size(^size), remaining::binary>> = rest
            {:ok, %{final: fin == 1, opcode: opcode, payload: payload}, remaining}
        end

      :more ->
        :more

      _ ->
        :error
    end
  end

  def decode(bytes) when byte_size(bytes) < 2, do: :more
  def decode(_), do: :error

  @spec encode(:text | :binary | :ping | :pong | :close, binary()) :: {:ok, binary()} | :error
  def encode(kind, payload) when is_binary(payload) and byte_size(payload) <= @maximum do
    opcode =
      case kind do
        :text -> 1
        :binary -> 2
        :close -> 8
        :ping -> 9
        :pong -> 10
        _ -> nil
      end

    if opcode && (opcode < 8 or byte_size(payload) <= 125) do
      mask = :crypto.strong_rand_bytes(4)
      size = byte_size(payload)

      length =
        cond do
          size < 126 -> <<1::1, size::7>>
          size <= 65535 -> <<1::1, 126::7, size::16>>
          true -> <<1::1, 127::7, size::64>>
        end

      {:ok, <<1::1, 0::3, opcode::4, length::binary, mask::binary, mask(payload, mask)::binary>>}
    else
      :error
    end
  end

  def encode(_, _), do: :error

  defp size(126, <<size::16, rest::binary>>) when size >= 126, do: {:ok, size, rest}
  defp size(126, rest) when byte_size(rest) < 2, do: :more
  defp size(127, <<0::1, size::63, rest::binary>>) when size > 65535, do: {:ok, size, rest}
  defp size(127, rest) when byte_size(rest) < 8, do: :more
  defp size(size, rest) when size < 126, do: {:ok, size, rest}
  defp size(_, _), do: :error

  defp mask(bytes, mask) do
    repeated = binary_part(:binary.copy(mask, div(byte_size(bytes) + 3, 4)), 0, byte_size(bytes))
    :crypto.exor(bytes, repeated)
  end
end
