defmodule Brady.Cache.RangeTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Brady.Cache.Range

  property "selected ranges remain entirely within the complete object" do
    check all(
            size <- integer(0..100_000),
            first <- integer(0..200_000),
            last <- integer(0..200_000)
          ) do
      for range <- ["bytes=#{first}-#{last}", "bytes=#{first}-", "bytes=-#{last}"] do
        case Range.select([{"range", range}], [], size) do
          {:partial, offset, length} ->
            assert offset >= 0 and length > 0 and offset + length <= size

          other ->
            assert other in [:upstream, :unsatisfiable]
        end
      end
    end
  end

  test "ranges require matching strong representation validators" do
    assert {:partial, 0, 4} =
             Range.select(
               [{"range", "bytes=0-3"}, {"if-range", ~s("one")}],
               [{"etag", ~s("one")}],
               10
             )

    assert :upstream =
             Range.select(
               [{"range", "bytes=0-3"}, {"if-range", ~s("two")}],
               [{"etag", ~s("one")}],
               10
             )

    assert :upstream =
             Range.select(
               [{"range", "bytes=0-3"}, {"if-range", ~s(W/"one")}],
               [{"etag", ~s(W/"one")}],
               10
             )

    assert :upstream = Range.select([{"range", "bytes=0-3,5-9"}], [], 10)
    assert :unsatisfiable = Range.select([{"range", "bytes=10-"}], [], 10)
    assert {:partial, 7, 3} = Range.select([{"range", "bytes=-3"}], [], 10)
  end
end
