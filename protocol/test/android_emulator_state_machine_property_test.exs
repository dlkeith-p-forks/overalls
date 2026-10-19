defmodule OverallsProtocol.AndroidEmulatorStateMachinePropertyTest do
  use ExUnit.Case, async: true

  import Hegel
  import Hegel.Gen

  defmodule Model do
    @moduledoc """
    Pure lifecycle/lease model for the software Android emulator.

    This model is deliberately independent of the eventual emulator process and ADB
    transport. It specifies the lease and boot fencing that the production adapter must
    satisfy when integrated.
    """

    @type phase :: :stopped | :booting | :running | :stopping | :failed
    @type owner :: :alice | :bob
    @type t :: %{
            phase: phase(),
            owner: owner() | nil,
            generation: non_neg_integer(),
            boot_id: pos_integer() | nil,
            marker: boolean()
          }
    @type action ::
            {:acquire, owner()}
            | {:booted, owner(), pos_integer()}
            | {:stop, owner()}
            | {:stopped, owner()}
            | {:failed, owner()}
            | {:release, owner(), non_neg_integer()}
            | {:reboot, owner()}
            | {:write_marker, owner()}

    @spec initial() :: t()
    def initial, do: %{phase: :stopped, owner: nil, generation: 0, boot_id: nil, marker: false}

    # @cc [owner:ghuntley,label:security;recovery] emulator-lease-generation-fence
    # A software-emulator lifecycle MUST mutate only under the current owner and
    # generation. A stale or foreign release MUST leave phase, owner, generation and
    # boot identity unchanged.
    def apply(%{phase: :running, owner: owner} = state, {:reboot, owner}),
      do: {:ok, %{state | phase: :booting, boot_id: nil}}

    def apply(%{phase: :running, owner: owner} = state, {:write_marker, owner}),
      do: {:ok, %{state | marker: true}}

    @spec apply(t(), action()) :: {:ok, t()} | {:error, atom()}
    def apply(state, {:acquire, owner}) do
      if state.owner == nil and state.phase in [:stopped, :failed] do
        {:ok,
         %{state | phase: :booting, owner: owner, generation: state.generation + 1, boot_id: nil}}
      else
        {:error, :lease_busy}
      end
    end

    def apply(%{phase: :booting, owner: owner} = state, {:booted, owner, boot_id})
        when is_integer(boot_id) and boot_id > 0,
        do: {:ok, %{state | phase: :running, boot_id: boot_id}}

    def apply(%{phase: phase, owner: owner} = state, {:stop, owner})
        when phase in [:booting, :running],
        do: {:ok, %{state | phase: :stopping}}

    def apply(%{phase: :stopping, owner: owner} = state, {:stopped, owner}),
      do: {:ok, %{state | phase: :stopped, owner: nil, boot_id: nil}}

    def apply(%{phase: phase, owner: owner} = state, {:failed, owner})
        when phase in [:booting, :running, :stopping],
        do: {:ok, %{state | phase: :failed, owner: nil, boot_id: nil}}

    def apply(%{owner: owner, generation: generation} = state, {:release, owner, generation}),
      do: {:ok, %{state | phase: :stopped, owner: nil, boot_id: nil}}

    def apply(_state, _action), do: {:error, :invalid_transition}
  end

  @actions [
    {:acquire, :alice},
    {:acquire, :bob},
    {:booted, :alice, 1},
    {:booted, :bob, 2},
    {:stop, :alice},
    {:stop, :bob},
    {:stopped, :alice},
    {:stopped, :bob},
    {:failed, :alice},
    {:failed, :bob},
    {:release, :alice, 0},
    {:release, :alice, 1},
    {:release, :bob, 0},
    {:release, :bob, 1},
    {:reboot, :alice},
    {:reboot, :bob},
    {:write_marker, :alice},
    {:write_marker, :bob}
  ]

  # @cc [owner:ghuntley,label:verification;recovery] emulator-state-machine-invariants
  # Every generated command sequence MUST preserve lease ownership, monotonic
  # generations and boot identity fencing. Rejected commands are observationally
  # pure. This is a logical property only; it does not establish native emulator,
  # Android boot, ADB transport or screenshot evidence.
  @tag :hegel
  property "lifecycle commands preserve lease and boot fencing",
    database: :disabled,
    print_blob: false,
    test_cases: 200,
    seed: 20_261_018 do
    actions = draw("actions", list_of(member_of(@actions), min_length: 1, max_length: 80))

    {_state, _previous_generation} =
      Enum.reduce(actions, {Model.initial(), 0}, fn action, {state, previous_generation} ->
        before = state

        case Model.apply(state, action) do
          {:error, _reason} ->
            assert state == before
            {state, previous_generation}

          {:ok, next} ->
            assert next.generation >= previous_generation
            assert next.owner != nil or next.phase in [:stopped, :failed]

            if next.phase == :running do
              assert next.owner != nil
              assert is_integer(next.boot_id) and next.boot_id > 0
            else
              assert next.boot_id == nil or next.phase in [:booting, :stopping]
            end

            if before.marker, do: assert(next.marker)

            {next, next.generation}
        end
      end)
  end

  test "stale releases are observationally pure" do
    state = Model.initial()
    assert {:ok, leased} = Model.apply(state, {:acquire, :alice})

    assert {:error, :invalid_transition} =
             Model.apply(leased, {:release, :bob, leased.generation})

    assert {:error, :invalid_transition} =
             Model.apply(leased, {:release, :alice, leased.generation - 1})
  end
end
