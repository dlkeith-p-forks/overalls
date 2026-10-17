defmodule OverallsProtocol.MachineTest do
  use ExUnit.Case, async: true
  use ExUnitProperties
  alias OverallsProtocol.{Cadence, Machine}

  @states [:a, :b, :c, :d]
  @events [:x, :y, :z]

  test "every pair of a declared machine reaches its table target or is refused" do
    for {state, event, expected} <- Machine.cases(Cadence) do
      assert Cadence.target(state, event) == expected
    end

    assert length(Machine.cases(Cadence)) == length(Cadence.states()) * length(Cadence.events())
  end

  property "check/2 accepts exactly closed, unique, reachable tables" do
    check all(
            initial <- member_of(@states),
            edges <-
              list_of(tuple({member_of(@states), member_of(@events), member_of(@states)}),
                max_length: 12
              )
          ) do
      duplicate? =
        edges
        |> Enum.frequencies_by(fn {f, e, _} -> {f, e} end)
        |> Enum.any?(fn {_, n} -> n > 1 end)

      states = Machine.states_of(initial, edges)
      reached = reach(initial, edges)

      expected_ok =
        not duplicate? and (edges == [] or Enum.any?(edges, &(elem(&1, 0) == initial))) and
          Enum.all?(states, &(&1 in reached))

      assert Machine.check(initial, edges) == :ok == expected_ok
    end
  end

  test "a malformed table fails compilation instead of producing a permissive machine" do
    for edges <- [
          "[a: [x: :b], a: [x: :c]]",
          "[a: [x: :a], b: [x: :a]]",
          "[b: [x: :a]]"
        ] do
      source = """
      defmodule OverallsProtocol.MachineTest.Bad#{System.unique_integer([:positive])} do
        use OverallsProtocol.Machine, initial: :a, edges: #{edges}
      end
      """

      assert_raise ArgumentError, ~r/invalid machine table/, fn -> Code.compile_string(source) end
    end
  end

  defp reach(initial, edges), do: reach([initial], MapSet.new([initial]), edges)
  defp reach([], seen, _edges), do: seen

  defp reach([state | rest], seen, edges) do
    next = for {^state, _, to} <- edges, not MapSet.member?(seen, to), uniq: true, do: to
    reach(rest ++ next, Enum.into(next, seen), edges)
  end
end
