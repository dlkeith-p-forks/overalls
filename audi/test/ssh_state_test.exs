defmodule Audi.SSH.StateTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias Audi.SSH.State

  property "arbitrary request histories cannot acquire authority twice or escape diagnostics" do
    check all(
            events <-
              list_of(member_of([:pty, :shell, :exec, :opened, :close, :other]), max_length: 100)
          ) do
      Enum.reduce(events, {:awaiting, false, false, 0}, fn event,
                                                           {state, diagnostic, closed, opens} ->
        {next, effect} = State.step(state, event)
        opens = opens + if(effect == :authorize, do: 1, else: 0)
        assert opens <= 1
        if diagnostic or closed, do: refute(next in [:opening, :relaying])
        if closed, do: assert(next == :closed)
        if next == :relaying, do: assert(opens == 1 and event == :opened)
        {next, diagnostic or next == :diagnostic, closed or next == :closed, opens}
      end)
    end
  end

  test "stream admission requires an exec then a successful open" do
    assert {:opening, :authorize} = State.step(:awaiting, :exec)
    assert {:relaying, :relay} = State.step(:opening, :opened)
    assert {:closed, :close} = State.step(:relaying, :exec)
    assert {:closed, :close} = State.step(:awaiting, :opened)
  end

  test "PTY and shell select diagnostics only" do
    assert {:diagnostic, :acknowledge} = State.step(:awaiting, :pty)
    assert {:diagnostic, :guide} = State.step(:diagnostic, :shell)
    assert {:diagnostic, :guide} = State.step(:awaiting, :shell)
    assert {:diagnostic, :guide} = State.step(:diagnostic, :exec)
  end
end
