defmodule Brady.Cache.BudgetTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Brady.Cache.Budget

  property "defaults bound both the pool share and each object" do
    check all(total <- integer(100..100_000_000_000_000)) do
      limits = Budget.defaults(total)
      assert limits.quota <= div(total, 10)
      assert limits.quota <= 256 * 1_073_741_824
      assert limits.object <= div(limits.quota, 10)
      assert limits.object <= 16 * 1_073_741_824
      assert limits.low <= limits.high
      assert limits.high < limits.quota
    end
  end

  property "concurrent pending writes cannot escape the quota" do
    check all(
            quota <- positive_integer(),
            committed <- non_negative_integer(),
            pending <- non_negative_integer(),
            more <- non_negative_integer()
          ) do
      if Budget.fits?(quota, committed, pending, more) do
        assert committed + pending + more <= quota
        refute Budget.fits?(quota, committed, pending, quota + 1)
      end
    end
  end

  # @cc [owner:ghuntley,label:verification;capacity] brady-wide-budget-boundaries
  # Accounting MUST distinguish exact-fit and one-byte-overflow histories across
  # signed and unsigned 32-bit boundaries without truncating cumulative leases.
  property "wide pending prefixes distinguish exact quota and one-byte overflow" do
    check all(
            boundary <- member_of([2_147_483_648, 4_294_967_296]),
            delta <- integer(-65_537..65_537),
            chunks <- list_of(integer(0..65_536), min_length: 1, max_length: 8)
          ) do
      committed = boundary + delta
      quota = committed + Enum.sum(chunks)

      Enum.reduce(chunks, 0, fn chunk, pending ->
        assert Budget.fits?(quota, committed, pending, chunk)
        assert Budget.fits?(quota, committed, pending, quota - committed - pending)
        refute Budget.fits?(quota, committed, pending, quota - committed - pending + 1)
        pending + chunk
      end)

      refute Budget.fits?(quota, committed, Enum.sum(chunks), 1)
    end
  end

  test "pressure hysteresis and missing evidence" do
    assert Budget.writable?(true, 15, 100, true)
    refute Budget.writable?(true, 14, 100, true)
    refute Budget.writable?(false, 20, 100, true)
    assert Budget.writable?(false, 21, 100, true)
    refute Budget.writable?(true, nil, 100, true)
    refute Budget.writable?(true, 101, 100, true)
    refute Budget.writable?(true, 99, 100, false)
    refute Budget.fits?(100, -1, 0, 1)
  end
end
