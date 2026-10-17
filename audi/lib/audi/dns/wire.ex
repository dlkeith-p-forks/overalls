defmodule Audi.DNS.Wire do
  @moduledoc "Bounded DNS question decoding, independent of routing and authority."
  import Bitwise

  @type question :: %{
          id: non_neg_integer(),
          flags: non_neg_integer(),
          labels: [binary()],
          wire_labels: [binary()],
          type: non_neg_integer(),
          class: non_neg_integer(),
          udp_size: pos_integer(),
          edns: boolean(),
          edns_version: non_neg_integer()
        }

  # @cc [owner:ghuntley,label:security] dns-decode-bounded
  # Decode MUST reject malformed framing, pointer cycles and overlong names
  # without raising. The decoder MUST NOT create atoms or allocate from claimed
  # record counts. Only one question and at most one OPT record are accepted.
  @spec decode(binary()) :: {:ok, question()} | {:error, :malformed | :response}
  def decode(packet) when is_binary(packet) and byte_size(packet) <= 65_535 do
    case packet do
      <<id::16, flags::16, 1::16, 0::16, 0::16, additional::16, _::binary>>
      when additional in 0..1 ->
        if (flags &&& 0x8000) == 0 do
          decode_question(packet, id, flags, additional)
        else
          {:error, :response}
        end

      _ ->
        {:error, :malformed}
    end
  end

  def decode(_), do: {:error, :malformed}

  @type resource_record :: {[binary()], non_neg_integer(), non_neg_integer(), binary()}

  # @cc [owner:ghuntley,label:protocol] dns-response-framing
  # Records MUST be validated local values. UDP overflow MUST truncate whole
  # sections with TC set; TCP MUST retain complete records. EDNS extended errors
  # MUST use OPT and the server MUST NOT advertise recursion or DNSSEC validation.
  @spec reply(
          question(),
          non_neg_integer(),
          [resource_record()],
          [resource_record()],
          boolean(),
          :udp | :tcp
        ) ::
          binary()
  def reply(question, code, answers, authority, authoritative, transport) do
    flags = 0x8000 ||| (question.flags &&& 0x7910) ||| (code &&& 15)
    flags = if authoritative, do: flags ||| 0x0400, else: flags
    packet = response(question, flags, code, answers, authority)
    limit = if transport == :tcp, do: 65_535, else: question.udp_size

    if byte_size(packet) <= limit,
      do: packet,
      else: response(question, flags ||| 0x0200, code, [], [])
  end

  @spec malformed(binary()) :: binary() | :drop
  def malformed(<<id::16, 0::1, flags::15, _::binary>>) do
    <<id::16, 0x8001 ||| (flags &&& 0x7910)::16, 0::64>>
  end

  def malformed(_), do: :drop

  @spec encode_name([binary()]) :: binary()
  def encode_name(labels),
    do:
      IO.iodata_to_binary([
        Enum.map(labels, fn label -> [<<byte_size(label)>>, label] end),
        <<0>>
      ])

  defp response(question, flags, code, answers, authority) do
    opt = if question.edns, do: <<0, 41::16, 1232::16, code >>> 4, 0, 0::16, 0::16>>, else: <<>>
    additional = if question.edns, do: 1, else: 0

    IO.iodata_to_binary([
      <<question.id::16, flags::16, 1::16, length(answers)::16, length(authority)::16,
        additional::16>>,
      encode_name(question.wire_labels),
      <<question.type::16, question.class::16>>,
      Enum.map(answers, &record/1),
      Enum.map(authority, &record/1),
      opt
    ])
  end

  defp record({labels, type, ttl, data}) do
    [encode_name(labels), <<type::16, 1::16, ttl::32, byte_size(data)::16>>, data]
  end

  defp decode_question(packet, id, flags, additional) do
    with {:ok, labels, offset} <- name(packet, 12, %{}, 0, []),
         <<type::16, class::16, tail::binary>> <- remaining(packet, offset),
         {:ok, options} <- opt(tail, additional) do
      {:ok,
       Map.merge(options, %{
         id: id,
         flags: flags,
         labels: Enum.map(labels, &ascii_lower/1),
         wire_labels: labels,
         type: type,
         class: class
       })}
    else
      _ -> {:error, :malformed}
    end
  end

  defp opt(<<>>, 0), do: {:ok, %{udp_size: 512, edns: false, edns_version: 0}}

  defp opt(<<0, 41::16, size::16, 0, version, _flags::16, length::16, data::binary>>, 1)
       when byte_size(data) == length do
    if valid_options?(data) do
      {:ok, %{udp_size: min(max(size, 512), 1232), edns: true, edns_version: version}}
    else
      {:error, :malformed}
    end
  end

  defp opt(_, _), do: {:error, :malformed}

  defp valid_options?(<<>>), do: true

  defp valid_options?(<<_code::16, size::16, _value::binary-size(size), rest::binary>>),
    do: valid_options?(rest)

  defp valid_options?(_), do: false

  @spec name(
          binary(),
          non_neg_integer(),
          %{optional(non_neg_integer()) => true},
          non_neg_integer(),
          [
            binary()
          ]
        ) ::
          {:ok, [binary()], non_neg_integer()} | {:error, :malformed}
  defp name(packet, offset, visited, length, labels) do
    if length >= 255 or map_size(visited) >= 128 or Map.has_key?(visited, offset) do
      {:error, :malformed}
    else
      visited = Map.put(visited, offset, true)

      case remaining(packet, offset) do
        <<0, _::binary>> ->
          {:ok, Enum.reverse(labels), offset + 1}

        <<3::2, pointer::14, _::binary>> when pointer >= 12 and pointer < offset ->
          case name(packet, pointer, visited, length, labels) do
            {:ok, result, _} -> {:ok, result, offset + 2}
            error -> error
          end

        <<size, label::binary-size(size), _::binary>> when size in 1..63 ->
          name(packet, offset + size + 1, visited, length + size + 1, [label | labels])

        _ ->
          {:error, :malformed}
      end
    end
  end

  defp remaining(packet, offset) when offset < byte_size(packet),
    do: binary_part(packet, offset, byte_size(packet) - offset)

  defp remaining(_, _), do: <<>>

  defp ascii_lower(label) do
    for <<char <- label>>, into: <<>> do
      if char in ?A..?Z, do: <<char + 32>>, else: <<char>>
    end
  end
end
