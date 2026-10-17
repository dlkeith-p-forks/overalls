defmodule OverallsProtocol.Machine do
  @moduledoc """
  Pure, in-memory state machines declared as closed transition tables.

  A machine module declares `initial:` and `edges:` with the same vocabulary as
  Lilly's durable lifecycle resources:

      use OverallsProtocol.Machine,
        initial: :idle,
        edges: [idle: [tick: :running], running: [done: :idle]]

  Edges are `state => [event => target]`. Effects and data guards belong to the
  module's own step function, which MUST obtain every target from `target/2`, so
  no code path can reach a state the table does not declare. Durable lifecycles
  stay on Ash; this is for volatile authority that must start unproven.
  """

  @typedoc "A closed machine state."
  @type state :: atom()
  @typedoc "A closed event name; payloads are carried separately by the caller."
  @type event :: atom()
  @typedoc "One declared edge."
  @type edge :: {state(), event(), state()}
  @typedoc "Why a declared table is malformed."
  @type table_error ::
          {:unknown_initial, state()}
          | {:duplicate_edge, state(), event()}
          | {:unreachable, [state()]}
          | {:invalid_table, term()}

  @callback initial() :: state()
  @callback states() :: [state()]
  @callback events() :: [event()]
  @callback edges() :: [edge()]
  @callback target(state(), event()) :: {:ok, state()} | {:error, :invalid_transition}

  defmacro __using__(options) do
    initial = Keyword.fetch!(options, :initial)
    edges = Keyword.fetch!(options, :edges)

    quote bind_quoted: [initial: initial, edges: edges] do
      @behaviour OverallsProtocol.Machine
      @machine_edges OverallsProtocol.Machine.flatten!(initial, edges)
      @machine_states OverallsProtocol.Machine.states_of(initial, @machine_edges)
      @machine_events @machine_edges |> Enum.map(&elem(&1, 1)) |> Enum.uniq() |> Enum.sort()

      @impl OverallsProtocol.Machine
      @spec initial() :: OverallsProtocol.Machine.state()
      def initial, do: unquote(initial)

      @impl OverallsProtocol.Machine
      @spec states() :: [OverallsProtocol.Machine.state()]
      def states, do: @machine_states

      @impl OverallsProtocol.Machine
      @spec events() :: [OverallsProtocol.Machine.event()]
      def events, do: @machine_events

      @impl OverallsProtocol.Machine
      @spec edges() :: [OverallsProtocol.Machine.edge()]
      def edges, do: @machine_edges

      @impl OverallsProtocol.Machine
      @spec target(OverallsProtocol.Machine.state(), OverallsProtocol.Machine.event()) ::
              {:ok, OverallsProtocol.Machine.state()} | {:error, :invalid_transition}
      for {from, event, to} <- @machine_edges do
        def target(unquote(from), unquote(event)), do: {:ok, unquote(to)}
      end

      def target(_state, _event), do: {:error, :invalid_transition}
    end
  end

  # @cc [owner:ghuntley,label:architecture;verification] machine-closed-transition-table
  # A machine table MUST be closed: the initial state is declared, every
  # (state, event) pair appears at most once, every state is reachable from the
  # initial state, and target/2 MUST reject every undeclared pair. Compilation
  # MUST fail for a malformed table rather than produce a permissive machine.
  @doc false
  @spec flatten!(state(), keyword()) :: [edge()]
  def flatten!(initial, edges) do
    flat =
      for {from, transitions} <- edges, {event, to} <- transitions do
        {from, event, to}
      end

    case check(initial, flat) do
      :ok -> flat
      {:error, reason} -> raise ArgumentError, "invalid machine table: #{inspect(reason)}"
    end
  end

  @doc false
  @spec states_of(state(), [edge()]) :: [state()]
  def states_of(initial, edges) do
    [initial | Enum.flat_map(edges, fn {from, _event, to} -> [from, to] end)]
    |> Enum.uniq()
    |> Enum.sort()
  end

  @doc "Validates a flattened table; used at compile time and by tests."
  @spec check(state(), [edge()]) :: :ok | {:error, table_error()}
  def check(initial, edges) when is_atom(initial) and is_list(edges) do
    with :ok <- shape(edges),
         :ok <- unique(edges),
         :ok <- declared_initial(initial, edges) do
      reachable(initial, edges)
    end
  end

  def check(_initial, edges), do: {:error, {:invalid_table, edges}}

  @doc """
  Every (state, event) pair of a machine with its expected outcome.

  Tables are finite, so tests check the whole product exhaustively instead of
  sampling it: declared pairs must reach their target, all others must refuse.
  """
  @spec cases(module()) :: [{state(), event(), {:ok, state()} | {:error, :invalid_transition}}]
  def cases(machine) do
    declared = Map.new(machine.edges(), fn {from, event, to} -> {{from, event}, to} end)

    for state <- machine.states(), event <- machine.events() do
      expected =
        case Map.fetch(declared, {state, event}) do
          {:ok, to} -> {:ok, to}
          :error -> {:error, :invalid_transition}
        end

      {state, event, expected}
    end
  end

  defp shape(edges) do
    if Enum.all?(
         edges,
         &match?({from, event, to} when is_atom(from) and is_atom(event) and is_atom(to), &1)
       ),
       do: :ok,
       else: {:error, {:invalid_table, edges}}
  end

  defp unique(edges) do
    edges
    |> Enum.frequencies_by(fn {from, event, _to} -> {from, event} end)
    |> Enum.find(fn {_pair, count} -> count > 1 end)
    |> case do
      nil -> :ok
      {{from, event}, _count} -> {:error, {:duplicate_edge, from, event}}
    end
  end

  # A table without edges is a single-state machine; check/2 already proved the atom.
  defp declared_initial(_initial, []), do: :ok

  defp declared_initial(initial, edges) do
    if Enum.any?(edges, fn {from, _event, _to} -> from == initial end),
      do: :ok,
      else: {:error, {:unknown_initial, initial}}
  end

  defp reachable(initial, edges) do
    seen = walk([initial], MapSet.new([initial]), edges)
    unreachable = states_of(initial, edges) |> Enum.reject(&MapSet.member?(seen, &1))
    if unreachable == [], do: :ok, else: {:error, {:unreachable, unreachable}}
  end

  defp walk([], seen, _edges), do: seen

  defp walk([state | rest], seen, edges) do
    next =
      for {^state, _event, to} <- edges, not MapSet.member?(seen, to), uniq: true, do: to

    walk(rest ++ next, Enum.reduce(next, seen, &MapSet.put(&2, &1)), edges)
  end
end
