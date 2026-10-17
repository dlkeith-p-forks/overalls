defmodule OverallsProtocol.WebSocket.Frame do
  @moduledoc """
  Bounded RFC 6455 frame codec shared by every control-plane WebSocket peer.

  Pure functions only. Supports text, binary, close, ping and pong frames.
  Fragmentation, compression, extensions and reserved bits are refused. A
  client masks every frame it sends and expects unmasked frames; a server is
  the reverse. Decoding is incremental: callers keep the returned remainder.
  """

  @max_control 125

  @type frame ::
          {:text, binary()}
          | {:binary, binary()}
          | {:close, non_neg_integer() | nil, binary()}
          | {:ping, binary()}
          | {:pong, binary()}
  @type role :: :client | :server
  @type decode_error :: :protocol_error | :frame_too_large

  # @cc [owner:ghuntley,label:protocol;security] websocket-frame-bounded
  # encode/3 MUST mask exactly when the sender is a client and MUST refuse a
  # payload above the limit, or a control payload above 125 bytes, before any
  # delivery. decode/3 MUST return :more for a prefix, never read past the
  # declared length, and refuse fragmentation, reserved bits, unknown opcodes,
  # the wrong masking for the role and lengths above the limit.
  @doc "Encodes one final frame sent by `role`."
  @spec encode(frame(), role(), pos_integer()) :: {:ok, iodata()} | {:error, :frame_too_large}
  def encode(frame, role, limit) do
    {opcode, payload} = parts(frame)
    control? = opcode >= 8
    size = byte_size(payload)

    cond do
      control? and size > @max_control -> {:error, :frame_too_large}
      size > limit -> {:error, :frame_too_large}
      true -> {:ok, build(opcode, payload, role)}
    end
  end

  @doc "Decodes one frame sent by the peer of `role` (a client decodes server frames)."
  @spec decode(binary(), role(), pos_integer()) ::
          {:ok, frame(), binary()} | :more | {:error, decode_error()}
  def decode(buffer, role, limit) when is_binary(buffer) do
    with {:ok, header, rest} <- header(buffer),
         :ok <- valid_header(header, role, limit),
         {:ok, length, rest} <- length(header, rest, limit),
         {:ok, mask, rest} <- mask_key(header, rest),
         {:ok, payload, rest} <- take(rest, length) do
      frame(header.opcode, unmask(mask, payload), rest)
    end
  end

  @spec parts(frame()) :: {non_neg_integer(), binary()}
  defp parts({:text, payload}), do: {1, payload}
  defp parts({:binary, payload}), do: {2, payload}
  defp parts({:close, nil, _reason}), do: {8, <<>>}
  defp parts({:close, code, reason}), do: {8, <<code::16, reason::binary>>}
  defp parts({:ping, payload}), do: {9, payload}
  defp parts({:pong, payload}), do: {10, payload}

  @spec build(non_neg_integer(), binary(), role()) :: iodata()
  defp build(opcode, payload, role) do
    size = byte_size(payload)
    masked = if role == :client, do: 1, else: 0

    length =
      cond do
        size < 126 -> <<masked::1, size::7>>
        size < 65_536 -> <<masked::1, 126::7, size::16>>
        true -> <<masked::1, 127::7, size::64>>
      end

    if role == :client do
      key = :crypto.strong_rand_bytes(4)
      [<<1::1, 0::3, opcode::4>>, length, key, unmask(key, payload)]
    else
      [<<1::1, 0::3, opcode::4>>, length, payload]
    end
  end

  @spec header(binary()) :: {:ok, map(), binary()} | :more
  defp header(<<fin::1, rsv::3, opcode::4, masked::1, short::7, rest::binary>>),
    do: {:ok, %{fin: fin, rsv: rsv, opcode: opcode, masked: masked, short: short}, rest}

  defp header(_), do: :more

  @spec valid_header(map(), role(), pos_integer()) :: :ok | {:error, decode_error()}
  defp valid_header(
         %{fin: fin, rsv: rsv, opcode: opcode, masked: masked, short: short},
         role,
         _limit
       ) do
    # A client receives unmasked server frames; a server receives masked ones.
    expected_mask = if role == :client, do: 0, else: 1

    cond do
      fin != 1 or rsv != 0 -> {:error, :protocol_error}
      opcode not in [1, 2, 8, 9, 10] -> {:error, :protocol_error}
      masked != expected_mask -> {:error, :protocol_error}
      opcode >= 8 and short > @max_control -> {:error, :protocol_error}
      true -> :ok
    end
  end

  @spec length(map(), binary(), pos_integer()) ::
          {:ok, non_neg_integer(), binary()} | :more | {:error, decode_error()}
  defp length(%{short: short}, rest, limit) when short < 126, do: bounded(short, rest, limit)

  defp length(%{short: 126}, <<size::16, rest::binary>>, limit) when size >= 126,
    do: bounded(size, rest, limit)

  defp length(%{short: 127}, <<0::1, size::63, rest::binary>>, limit) when size >= 65_536,
    do: bounded(size, rest, limit)

  defp length(%{short: 126}, rest, _limit) when byte_size(rest) < 2, do: :more
  defp length(%{short: 127}, rest, _limit) when byte_size(rest) < 8, do: :more
  defp length(_header, _rest, _limit), do: {:error, :protocol_error}

  @spec bounded(non_neg_integer(), binary(), pos_integer()) ::
          {:ok, non_neg_integer(), binary()} | {:error, :frame_too_large}
  defp bounded(size, rest, limit) when size <= limit, do: {:ok, size, rest}
  defp bounded(_size, _rest, _limit), do: {:error, :frame_too_large}

  @spec mask_key(map(), binary()) :: {:ok, binary() | nil, binary()} | :more
  defp mask_key(%{masked: 0}, rest), do: {:ok, nil, rest}
  defp mask_key(%{masked: 1}, <<key::binary-size(4), rest::binary>>), do: {:ok, key, rest}
  defp mask_key(_header, _rest), do: :more

  @spec take(binary(), non_neg_integer()) :: {:ok, binary(), binary()} | :more
  defp take(rest, length) when byte_size(rest) >= length,
    do: {:ok, binary_part(rest, 0, length), binary_part(rest, length, byte_size(rest) - length)}

  defp take(_rest, _length), do: :more

  @spec frame(non_neg_integer(), binary(), binary()) ::
          {:ok, frame(), binary()} | {:error, :protocol_error}
  defp frame(1, payload, rest) do
    if String.valid?(payload), do: {:ok, {:text, payload}, rest}, else: {:error, :protocol_error}
  end

  defp frame(2, payload, rest), do: {:ok, {:binary, payload}, rest}
  defp frame(8, <<>>, rest), do: {:ok, {:close, nil, <<>>}, rest}
  defp frame(8, <<code::16, reason::binary>>, rest), do: {:ok, {:close, code, reason}, rest}
  defp frame(8, _payload, _rest), do: {:error, :protocol_error}
  defp frame(9, payload, rest), do: {:ok, {:ping, payload}, rest}
  defp frame(10, payload, rest), do: {:ok, {:pong, payload}, rest}

  @doc "XORs `payload` with the 4-byte masking key (masking is its own inverse)."
  @spec unmask(binary() | nil, binary()) :: binary()
  def unmask(nil, payload), do: payload
  def unmask(_key, <<>>), do: <<>>

  def unmask(<<_::binary-size(4)>> = key, payload) do
    size = byte_size(payload)
    stream = binary_part(:binary.copy(key, div(size, 4) + 1), 0, size)
    :crypto.exor(payload, stream)
  end
end
