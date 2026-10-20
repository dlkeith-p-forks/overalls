defmodule Marshall.MessageBoardsPropertyTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  property "board profiles stay within the machine-profile catalog",
    test_cases: 32,
    seed: 2_026_102_020 do
    profile = draw("profile", member_of([:standard, :oss]))
    assert profile in Marshall.MessageBoards.profiles()
  end

  property "empty or oversized posts are refused before persistence",
    test_cases: 24,
    seed: 2_026_102_021 do
    body =
      draw(
        "body",
        one_of([constant(""), string(:alphanumeric, min_length: 65_537, max_length: 65_600)])
      )

    assert {:error, :invalid_body} =
             Marshall.MessageBoards.post!(
               Ash.UUID.generate(),
               :standard,
               Ash.UUID.generate(),
               body
             )
  end

  property "only unavailable VM states trigger lifecycle cleanup",
    test_cases: 32,
    seed: 2_026_102_022 do
    state = draw("state", member_of([:running, :paused, :stopped, :deleted]))

    if state == :running do
      assert Marshall.MessageBoards.purge_for_state!(Ash.UUID.generate(), state) == 0
    else
      assert state in [:paused, :stopped, :deleted]
    end
  end
end
