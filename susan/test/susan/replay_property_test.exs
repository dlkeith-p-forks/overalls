defmodule Susan.ReplayPropertyTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias Susan.Replay

  test "fresh nonces are admitted once and stale times are refused" do
    {:ok, seen} = Replay.check(%{}, "i", "n", 1000, 1000)
    assert {:error, :replayed, ^seen} = Replay.check(seen, "i", "n", 1000, 1001)
    assert {:ok, _} = Replay.check(seen, "other", "n", 1000, 1001)
    assert {:error, :stale, _} = Replay.check(%{}, "i", "m", 1000, 1301)
    assert {:error, :stale, _} = Replay.check(%{}, "i", "m", 1301, 1000)
    assert {:ok, _} = Replay.check(%{}, "i", "m", 1300, 1000)
  end

  @tag :hegel
  test "no (install, nonce) pair is ever admitted twice while it could be fresh" do
    Hegel.check(
      fn ->
        operations =
          draw(
            "operations",
            list_of(tuple({integer(0, 2), integer(0, 5), integer(-400, 400), integer(0, 200)}),
              max_length: 60
            )
          )

        {_, _, admitted} =
          Enum.reduce(operations, {%{}, 10_000, []}, fn {install, nonce, offset, advance},
                                                        {seen, now, admitted} ->
            now = now + advance
            seen = if rem(advance, 7) == 0, do: Replay.forget(seen, now), else: seen
            key = {Integer.to_string(install), Integer.to_string(nonce)}
            issued = now + offset

            case Replay.check(seen, elem(key, 0), elem(key, 1), issued, now) do
              {:ok, next} ->
                assert abs(offset) <= Replay.window_seconds()
                {next, now, [{key, now} | admitted]}

              {:error, :stale, ^seen} ->
                assert abs(offset) > Replay.window_seconds()
                {seen, now, admitted}

              {:error, :replayed, ^seen} ->
                assert Enum.any?(admitted, &(elem(&1, 0) == key))
                {seen, now, admitted}
            end
          end)

        # A pair admitted twice must be separated by more than twice the
        # window, so the same signed issued_at could no longer be fresh.
        admitted
        |> Enum.group_by(&elem(&1, 0), &elem(&1, 1))
        |> Enum.each(fn {_key, times} ->
          times
          |> Enum.sort()
          |> Enum.chunk_every(2, 1, :discard)
          |> Enum.each(fn [a, b] -> assert b - a > 2 * Replay.window_seconds() end)
        end)
      end,
      test_cases: 300
    )
  end
end
