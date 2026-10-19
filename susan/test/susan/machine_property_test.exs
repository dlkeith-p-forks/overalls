defmodule Susan.Poke.MachinePropertyTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen

  alias Susan.Poke.Machine

  @events [
    :valid,
    :invalid,
    :authenticated,
    {:refused, :unknown_key},
    {:refused, :bad_signature},
    {:refused, :unregistered},
    {:refused, :install_blocked},
    {:refused, :replayed},
    {:refused, :stale},
    :fresh,
    :duplicate,
    :in_flight,
    :admitted,
    {:limited, :key, 60},
    :claimed,
    :sent,
    :unregistered,
    {:retry, 1},
    {:retry, 30},
    :rejected,
    :unavailable,
    :nonsense
  ]

  test "the happy path validates, checks, claims, sends once and answers 204" do
    {m, :validate} = Machine.start()
    {m, :authenticate} = Machine.next(m, :valid)
    {m, :check_replay} = Machine.next(m, :authenticated)
    {m, :check_rate} = Machine.next(m, :fresh)
    {m, :claim} = Machine.next(m, :admitted)
    {m, {:send, 1}} = Machine.next(m, :claimed)
    {m, {:send, 2}} = Machine.next(m, {:retry, 1})
    assert {m, {:respond, 204, :empty, nil}} = Machine.next(m, :sent)
    assert Machine.done?(m)
  end

  test "unauthenticated refusals share the 404 shape and dead tokens answer 410" do
    {m, _} = Machine.start()
    {m, _} = Machine.next(m, :valid)
    assert {_, {:respond, 404, :rejected, nil}} = Machine.next(m, {:refused, :unknown_key})
    assert {_, {:respond, 404, :rejected, nil}} = Machine.next(m, {:refused, :bad_signature})
    assert {_, {:respond, 410, :unregistered, nil}} = Machine.next(m, {:refused, :unregistered})
  end

  @tag :hegel
  test "arbitrary event sequences never send before every check and always answer once" do
    Hegel.check(
      fn ->
        events = draw("events", list_of(member_of(@events), min_length: 1, max_length: 12))
        {machine, command} = Machine.start()

        {trace, final} =
          Enum.reduce_while(events, {[command], machine}, fn event, {trace, machine} ->
            if Machine.done?(machine) do
              {:halt, {trace, machine}}
            else
              {machine, command} = Machine.next(machine, event)
              {:cont, {[command | trace], machine}}
            end
          end)

        trace = Enum.reverse(trace)
        sends = Enum.filter(trace, &match?({:send, _}, &1))
        responses = Enum.filter(trace, &match?({:respond, _, _, _}, &1))

        assert length(sends) <= 2
        assert length(responses) <= 1
        if Machine.done?(final), do: assert(length(responses) == 1)

        # Every send follows validation, authentication, replay, rate and claim.
        if sends != [] do
          prefix = Enum.take_while(trace, &(not match?({:send, _}, &1)))
          assert prefix == [:validate, :authenticate, :check_replay, :check_rate, :claim]

          assert final.checks |> Enum.reverse() |> Enum.take(5) == [
                   :valid,
                   :authenticated,
                   :fresh,
                   :admitted,
                   :claimed
                 ]
        end

        case responses do
          [{:respond, 204, :empty, nil}] ->
            assert sends != [] or :check_replay in trace or :claim in trace

          [{:respond, status, _, retry}] when status in [429, 503] ->
            assert is_integer(retry) and retry > 0

          _ ->
            :ok
        end

        # Machine state carries only control flow, never payload data.
        assert Map.keys(Map.from_struct(final)) |> Enum.sort() == [:attempt, :checks, :step]
      end,
      test_cases: 500
    )
  end
end
