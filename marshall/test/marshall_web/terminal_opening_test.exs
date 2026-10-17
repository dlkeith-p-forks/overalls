defmodule MarshallWeb.TerminalOpeningTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias MarshallWeb.TerminalOpening, as: Opening

  property "transient failure histories preserve execution and never resurrect closed shells" do
    check all(
            phase <- member_of([:waiting, :opening, :ready, :closed, :failed]),
            errors <-
              list_of(
                member_of([
                  :terminal_open_pending,
                  :terminal_unavailable,
                  :stream_unavailable,
                  :stream_timeout,
                  :stream_busy,
                  :stream_not_ready,
                  :timeout
                ]),
                min_length: 1,
                max_length: 100
              )
          ) do
      initial = %{execution: "execution-one", phase: phase, rejections: 0}
      final = Enum.reduce(errors, initial, &Opening.failed(&2, &1))
      assert final == initial
      assert {_, action} = Opening.observe(final, "execution-one", true, true, false)
      assert action == if(phase in [:waiting, :opening], do: :open, else: :none)
      failed = Enum.reduce(1..5, final, fn _, state -> Opening.failed(state, :rejected) end)
      assert {^failed, :none} = Opening.observe(failed, "execution-one", true, true, false)
      assert {_, :open} = Opening.observe(failed, "execution-two", true, true, false)
    end
  end

  property "arbitrary polling cannot create a shell after closing or failure" do
    check all(
            phase <- member_of([:closed, :failed]),
            polls <- list_of({boolean(), boolean()}, max_length: 100)
          ) do
      state = %{execution: "execution-one", phase: phase, rejections: 0}

      Enum.reduce(polls, state, fn {running, writable}, state ->
        assert {next, :none} = Opening.observe(state, "execution-one", running, writable, false)
        assert next.phase == phase
        next
      end)
    end
  end

  property "a stopped or read-only machine never automatically opens" do
    check all(
            phase <- member_of([:waiting, :opening, :ready, :closed, :failed]),
            {running, writable} <- member_of([{false, false}, {false, true}, {true, false}]),
            sessions <- boolean()
          ) do
      assert {_, :none} =
               Opening.observe(
                 %{execution: "execution-one", phase: phase, rejections: 0},
                 "execution-one",
                 running,
                 writable,
                 sessions
               )
    end
  end

  # @cc [owner:ghuntley,label:verification;recovery] terminal-rejection-budget
  # A guest-account refusal (:rejected) MUST keep automatic opening pending for
  # four attempts and become definitive on the fifth; a new execution resets
  # the budget.
  test "guest account refusals retry within a budget, then fail definitively" do
    {opening, :open} = Opening.observe(Opening.new(), "execution-one", true, true, false)

    pending =
      Enum.reduce(1..4, opening, fn _, state ->
        state = Opening.failed(state, :rejected)
        assert Opening.pending?(state)
        assert {_, :open} = Opening.observe(state, "execution-one", true, true, false)
        state
      end)

    failed = Opening.failed(pending, :rejected)
    refute Opening.pending?(failed)
    assert {_, :none} = Opening.observe(failed, "execution-one", true, true, false)
    assert {reset, :open} = Opening.observe(failed, "execution-two", true, true, false)
    assert reset.rejections == 0
  end

  test "waiting, retry, ready, close and a new execution form an explicit lifecycle" do
    assert {waiting, :none} = Opening.observe(Opening.new(), "execution-one", false, true, false)
    assert {opening, :open} = Opening.observe(waiting, "execution-one", true, true, false)
    assert {^opening, :open} = Opening.observe(opening, "execution-one", true, true, false)
    assert {ready, :none} = Opening.observe(opening, "execution-one", true, true, true)
    assert ready.phase == :ready
    assert {closed, :none} = Opening.observe(ready, "execution-one", true, true, false)
    assert closed.phase == :closed
    assert {_, :open} = Opening.observe(closed, "execution-two", true, true, false)
  end
end
