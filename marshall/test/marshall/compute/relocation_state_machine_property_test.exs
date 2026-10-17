defmodule Marshall.Compute.RelocationStateMachinePropertyTest do
  # @cc [owner:ghuntley,label:verification] relocation-graph-is-stopped-copy-only
  # The declared Relocation state machine MUST admit only the ADR-0155 stopped
  # copy: every route to :copying passes :checking_transfer, cancellation exists
  # only before the handoff commit, terminal phases are sinks, every phase can
  # still finish, and no pre-copy phase remains declared.
  use Marshall.DataCase, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures

  alias Marshall.Compute.{Host, Ledger, Operation, Relocation, RelocationCapacity}
  alias Marshall.Compute.VirtualMachine

  @terminal [:complete, :cancelled, :deleted]
  @committed [
    :checking_destination,
    :readiness_failed,
    :activation_failed,
    :retrying_destination,
    :source_cleanup,
    :complete
  ]
  @removed [:baseline_copy, :final_copy]

  @spec edges() :: [{atom(), atom(), atom()}]
  defp edges do
    for transition <- AshStateMachine.Info.state_machine_transitions(Relocation),
        from <- List.wrap(transition.from),
        to <- List.wrap(transition.to),
        do: {transition.action, from, to}
  end

  @spec successors(atom()) :: [atom()]
  defp successors(state),
    do: edges() |> Enum.filter(&(elem(&1, 1) == state)) |> Enum.map(&elem(&1, 2)) |> Enum.uniq()

  @spec reachable(atom()) :: MapSet.t(atom())
  defp reachable(start), do: walk([start], MapSet.new([start]))

  defp walk([], seen), do: seen

  defp walk([state | rest], seen) do
    fresh = Enum.reject(successors(state), &MapSet.member?(seen, &1))
    walk(fresh ++ rest, Enum.reduce(fresh, seen, &MapSet.put(&2, &1)))
  end

  # A bounded random walk following only declared transitions.
  defp random_walk(choices) do
    Enum.reduce_while(choices, [:preparing], fn choice, [state | _] = path ->
      case successors(state) |> Enum.reject(&(&1 == state)) |> Enum.sort() do
        [] -> {:halt, path}
        next -> {:cont, [Enum.at(next, rem(choice, length(next))) | path]}
      end
    end)
    |> Enum.reverse()
  end

  test "removed pre-copy phases are not declared and every state is reachable" do
    states = AshStateMachine.Info.state_machine_all_states(Relocation)
    assert Enum.all?(@removed, &(&1 not in states))
    assert MapSet.new(states) == reachable(:preparing)
  end

  test "terminal phases are sinks and every other phase can still finish" do
    for state <- @terminal, do: assert(successors(state) == [])

    for state <- AshStateMachine.Info.state_machine_all_states(Relocation),
        state not in @terminal do
      assert Enum.any?(@terminal, &MapSet.member?(reachable(state), &1)),
             "#{state} cannot reach a terminal phase"
    end
  end

  test "cancellation is declared only before the handoff commit" do
    origins = for {:request_cancellation, from, _} <- edges(), do: from
    assert origins != []
    assert Enum.all?(origins, &(&1 not in @committed and &1 not in @terminal))

    for {:request_cancellation, _, to} <- edges(), do: assert(to == :restoring_source)
  end

  property "random declared walks reach copying only through connectivity checking" do
    check all(choices <- list_of(integer(0..15), min_length: 1, max_length: 24)) do
      path = random_walk(choices)
      assert hd(path) == :preparing

      for {before, index} <- Enum.with_index(path), before == :copying do
        prior = Enum.take(path, index)
        assert :checking_transfer in prior
        refute Enum.any?(prior, &(&1 in @committed))
      end

      # Once committed, a walk never returns to a pre-commit or restoring phase.
      case Enum.find_index(path, &(&1 in @committed)) do
        nil ->
          :ok

        index ->
          later = Enum.drop(path, index)

          refute Enum.any?(
                   later,
                   &(&1 in [
                       :preparing,
                       :checking_transfer,
                       :stopping_source,
                       :copying,
                       :importing,
                       :handoff,
                       :restoring_source,
                       :cancelled_cleanup,
                       :cancelled
                     ])
                 )
      end

      assert Enum.all?(path, &(&1 not in @removed))
    end
  end

  describe "record_key" do
    setup do
      source = host_fixture()
      owner = user()
      {:ok, vm} = Marshall.Compute.provision(request(), actor: owner)
      [operation] = Ledger.read!(Operation, vm_id: vm.id)
      Ledger.update!(operation, :complete, %{})
      vm = Ledger.update!(vm, :observe, %{observed_state: :running})
      host_fixture()

      {:ok, relocation} =
        Ledger.transaction(fn ->
          hosts =
            Host
            |> Ledger.read!()
            |> Enum.sort_by(& &1.id)
            |> Enum.map(&Ledger.lock!(Host, &1.id))

          locked = Ledger.lock!(VirtualMachine, vm.id)
          RelocationCapacity.reserve_locked!(locked, hosts, owner, Ash.UUID.generate())
        end)

      %{relocation: relocation, owner: owner, source: source}
    end

    test "moves preparing to connectivity checking and nothing else", c do
      assert c.relocation.phase == :preparing
      key = transfer_endpoint()["host_key"]
      keyed = Ledger.update!(c.relocation, :record_key, %{destination_public_key: key})
      assert keyed.phase == :checking_transfer
      assert keyed.source_stop_operation_id == nil
      assert Ledger.read!(Operation, relocation_id: c.relocation.id) == []
    end

    test "leaves a cancellation phase unchanged", c do
      assert {:ok, cancelled} =
               Marshall.Compute.cancel_relocation(%{relocation_id: c.relocation.id},
                 actor: c.owner
               )

      assert cancelled.phase == :restoring_source
      key = transfer_endpoint()["host_key"]
      keyed = Ledger.update!(cancelled, :record_key, %{destination_public_key: key})
      assert keyed.phase == :restoring_source
    end
  end
end
