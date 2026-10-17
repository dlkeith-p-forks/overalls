defmodule OverallsProtocol.TestGenerators do
  @moduledoc false

  import Hegel.Gen

  @type alphabet :: :alphanumeric | :printable | :utf8 | [non_neg_integer()] | Range.t()
  @type string_option ::
          {:length, non_neg_integer()}
          | {:min_length, non_neg_integer()}
          | {:max_length, non_neg_integer()}
  @type peer_term ::
          nil
          | boolean()
          | integer()
          | binary()
          | :invalid_fixture
          | [peer_term()]
          | %{optional(binary()) => peer_term()}
          | {peer_term(), peer_term()}

  # @cc [owner:ghuntley,label:verification] protocol-generated-peer-term-shapes
  # Malformed peer generation MUST retain nil, scalar, list, map and tuple shapes
  # with finite size/depth. It MUST NOT generate arbitrary atoms or BEAM resources.
  @spec peer_term() :: :hegel_gen.t(peer_term())
  def peer_term, do: peer_term(2)

  @spec peer_term(0..2) :: :hegel_gen.t(peer_term())
  defp peer_term(0),
    do: one_of([constant(nil), constant(:invalid_fixture), boolean(), integer(), binary(0, 64)])

  defp peer_term(depth) when depth in 1..2 do
    child = peer_term(depth - 1)

    one_of([
      peer_term(0),
      list(child, min: 0, max: 4),
      map_of(binary(0, 16), child, min: 0, max: 4),
      tuple([child, child])
    ])
  end

  # @cc [owner:ghuntley,label:verification] protocol-generated-unsigned-width
  # Unsigned GUID generation MUST cover every nonzero 64-bit value, including
  # values above the native engine's signed integer bound. Refusal generation
  # MUST retain the complete upper half instead of narrowing it to signed values.
  @spec positive_uint64() :: :hegel_gen.t(pos_integer())
  def positive_uint64 do
    tuple([integer(0, 0xFFFFFFFF), integer(0, 0xFFFFFFFF)])
    |> map(fn {high, low} -> high * 0x100000000 + low end)
    |> filter(&(&1 > 0))
  end

  @spec above_int64() :: :hegel_gen.t(pos_integer())
  def above_int64 do
    map(tuple([integer(0x80000000, 0xFFFFFFFF), integer(0, 0xFFFFFFFF)]), fn {high, low} ->
      high * 0x100000000 + low
    end)
  end

  # @cc [owner:ghuntley,label:verification] protocol-generated-string-bounds
  # Generated strings MUST respect their requested alphabet and character count.
  # Unicode generation MUST exclude surrogate codepoints and retain controls for
  # refusal/sanitization properties instead of replacing them with ASCII.
  @spec string(alphabet(), [string_option()]) :: :hegel_gen.t(String.t())
  def string(alphabet, options \\ []) do
    minimum = Keyword.get(options, :length, Keyword.get(options, :min_length, 0))
    maximum = Keyword.get(options, :length, Keyword.get(options, :max_length, 64))

    if minimum < 0 or maximum < minimum or maximum > 4096 do
      raise ArgumentError, "generated string character count is outside the test bounds"
    end

    map(list(character(alphabet), min: minimum, max: maximum), &List.to_string/1)
  end

  @spec character(alphabet()) :: :hegel_gen.t(non_neg_integer())
  defp character(:alphanumeric),
    do: member_of(Enum.concat([?a..?z, ?A..?Z, ?0..?9]))

  defp character(:printable), do: integer(32, 126)

  defp character(:utf8),
    do: one_of([integer(0, 0xD7FF), integer(0xE000, 0x10FFFF)])

  defp character(%Range{} = range), do: member_of(Enum.to_list(range))

  defp character(characters) when is_list(characters) and characters != [],
    do: member_of(characters)
end
