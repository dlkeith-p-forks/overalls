defmodule Brady.Cache.Budget do
  @moduledoc "Integer-only cache limits and hysteresis; unavailable pressure evidence denies writes."
  @gib 1_073_741_824
  @type limits :: %{
          quota: pos_integer(),
          object: pos_integer(),
          high: pos_integer(),
          low: pos_integer()
        }

  @spec defaults(pos_integer()) :: limits()
  def defaults(usable_pool_bytes)
      when is_integer(usable_pool_bytes) and usable_pool_bytes >= 100 do
    quota = min(div(usable_pool_bytes, 10), 256 * @gib)

    %{
      quota: quota,
      object: min(16 * @gib, div(quota, 10)),
      high: div(quota * 90, 100),
      low: div(quota * 80, 100)
    }
  end

  # @cc [owner:ghuntley,label:capacity] brady-pressure-unknown-denies
  # Missing or invalid pool observations MUST disable writes. Disabled writes
  # MUST resume only above 20 percent free; active writes stop below 15 percent.
  @spec writable?(boolean(), term(), term(), boolean()) :: boolean()
  def writable?(was_writable, available, total, lilly_safe)
      when is_boolean(was_writable) and is_integer(available) and is_integer(total) and
             available >= 0 and total > 0 and available <= total and lilly_safe == true do
    if was_writable, do: available * 100 >= total * 15, else: available * 100 > total * 20
  end

  def writable?(_, _, _, _), do: false

  # @cc [owner:ghuntley,label:capacity] brady-reservation-includes-inflight
  # Admission MUST include committed bytes and every pending write, and MUST
  # reject invalid accounting instead of manufacturing free space.
  @spec fits?(term(), term(), term(), term()) :: boolean()
  def fits?(quota, committed, pending, additional)
      when is_integer(quota) and quota > 0 and is_integer(committed) and committed >= 0 and
             is_integer(pending) and pending >= 0 and is_integer(additional) and additional >= 0,
      do: committed + pending + additional <= quota

  def fits?(_, _, _, _), do: false
end
