defmodule Brady.Cache.Range do
  @moduledoc "Bounded single-byte-range selection from an already complete cached representation."
  alias Brady.Cache.Policy

  @type selection ::
          :full | :upstream | :unsatisfiable | {:partial, non_neg_integer(), pos_integer()}

  # @cc [owner:ghuntley,label:security] brady-range-complete-representation
  # Callers MUST select only a fresh complete representation. Multiple/malformed
  # ranges and unmatched or weak If-Range validators MUST go upstream; range
  # selection MUST never combine bytes from different representation versions.
  @spec select(Policy.headers(), Policy.headers(), non_neg_integer()) :: selection()
  def select(request_headers, response_headers, size) when is_integer(size) and size >= 0 do
    case Policy.values(request_headers, "range") do
      [] ->
        :full

      [range] when byte_size(range) <= 128 ->
        if matches?(request_headers, response_headers), do: parse(range, size), else: :upstream

      _ ->
        :upstream
    end
  end

  defp matches?(request, response) do
    case Policy.values(request, "if-range") do
      [] ->
        true

      [value] ->
        (String.starts_with?(value, "\"") and Policy.values(response, "etag") == [value]) or
          (not String.starts_with?(value, ["W/", "\""]) and
             Policy.values(response, "last-modified") == [value])

      _ ->
        false
    end
  end

  defp parse(value, size) do
    case Regex.run(~r/\Abytes=([0-9]{0,20})-([0-9]{0,20})\z/, value, capture: :all_but_first) do
      ["", ""] ->
        :upstream

      ["", suffix] ->
        amount = String.to_integer(suffix)

        if amount == 0 or size == 0,
          do: :unsatisfiable,
          else: {:partial, max(0, size - amount), min(size, amount)}

      [first, last] ->
        start = String.to_integer(first)
        finish = if last == "", do: size - 1, else: String.to_integer(last)

        cond do
          last != "" and finish < start -> :upstream
          start >= size -> :unsatisfiable
          true -> {:partial, start, min(finish, size - 1) - start + 1}
        end

      _ ->
        :upstream
    end
  end
end
