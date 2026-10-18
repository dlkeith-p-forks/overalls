defmodule OverallsProtocol.AndroidDisplayStream do
  @moduledoc "Bounded binary framing for authenticated Android display streams."
  @maximum 262_144
  @type data :: %{generation: pos_integer(), sequence: pos_integer(), bytes: binary()}
  @type input :: %{generation: pos_integer(), kind: :key | :pointer, payload: binary()}

  # @cc [owner:ghuntley,label:security;protocol] android-display-stream-fencing
  # Display data and input MUST be generation-bound and bounded. A relay MUST
  # reject stale generations and frames larger than the configured window before
  # forwarding bytes to the browser or guest.
  @spec maximum() :: pos_integer()
  def maximum, do: @maximum

  @spec encode_data(pos_integer(), pos_integer(), binary()) ::
          {:ok, binary()} | {:error, :invalid_frame}
  def encode_data(generation, sequence, bytes)
      when is_integer(generation) and generation > 0 and is_integer(sequence) and sequence > 0 and
             is_binary(bytes) and byte_size(bytes) in 1..@maximum do
    {:ok,
     <<1, generation::unsigned-big-64, sequence::unsigned-big-64,
       byte_size(bytes)::unsigned-big-32, bytes::binary>>}
  end

  def encode_data(_, _, _), do: {:error, :invalid_frame}

  @spec decode_data(binary(), pos_integer()) :: {:ok, data()} | {:error, :invalid_frame}
  def decode_data(
        <<1, generation::unsigned-big-64, sequence::unsigned-big-64, length::unsigned-big-32,
          bytes::binary>>,
        expected_generation
      )
      when generation == expected_generation and generation > 0 and sequence > 0 and
             length == byte_size(bytes) and length in 1..@maximum,
      do: {:ok, %{generation: generation, sequence: sequence, bytes: bytes}}

  def decode_data(_, _), do: {:error, :invalid_frame}

  @spec encode_input(pos_integer(), :key | :pointer, binary()) ::
          {:ok, binary()} | {:error, :invalid_frame}
  def encode_input(generation, kind, payload)
      when is_integer(generation) and generation > 0 and kind in [:key, :pointer] and
             is_binary(payload) and byte_size(payload) in 1..4096 do
    {:ok,
     <<2, generation::unsigned-big-64, if(kind == :key, do: 1, else: 2),
       byte_size(payload)::unsigned-big-32, payload::binary>>}
  end

  def encode_input(_, _, _), do: {:error, :invalid_frame}
end
