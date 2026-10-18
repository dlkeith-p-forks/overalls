defmodule Marshall.Compute.RelocationRestorationPropertyTest do
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  import Marshall.ComputeFixtures

  alias Marshall.Compute.{
    Credentials,
    Host,
    Ledger,
    Operation,
    ProvisionerControl,
    RelocationCapacity,
    Reservation,
    VirtualMachine
  }

  @moduletag timeout: 180_000

  # @cc [owner:ghuntley,label:verification;recovery;capacity] generated-restoration-retry-authority
  # Unknown stop/start outcomes MUST NOT authorize restart or release reservations.
  # Exact failures MUST retain cancellation authority through bounded retries and
  # exhaustion; expired retry history MUST permit fenced restoration to recover.
  property "generated unknown outcomes retain restoration fencing across failed starts",
    test_cases: 4 do
    check all(
            stop_unknowns <- list_of(integer(1..3), length: 4),
            start_unknowns <- list_of(integer(1..3), length: 4),
            test_cases: 4
          ) do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(Marshall.Repo)

      try do
        c = fixture()
        journey(c, stop_unknowns, start_unknowns)
      after
        :ok = Ecto.Adapters.SQL.Sandbox.checkin(Marshall.Repo)
      end
    end
  end

  @type context :: %{
          vm: VirtualMachine.t(),
          relocation: Marshall.Compute.Relocation.t(),
          owner: Marshall.Accounts.User.t(),
          token: String.t(),
          session: map()
        }

  @spec fixture() :: context()
  defp fixture do
    source = host_fixture()
    owner = user()
    {:ok, vm} = Marshall.Compute.provision(request(), actor: owner)
    [operation] = Ledger.read!(Operation, vm_id: vm.id)
    Ledger.update!(operation, :complete, %{})
    vm = Ledger.update!(vm, :observe, %{observed_state: :running})
    _destination = host_fixture()

    {:ok, relocation} =
      Ledger.transaction(fn ->
        hosts =
          Host |> Ledger.read!() |> Enum.sort_by(& &1.id) |> Enum.map(&Ledger.lock!(Host, &1.id))

        vm = Ledger.lock!(VirtualMachine, vm.id)
        RelocationCapacity.reserve_locked!(vm, hosts, owner, Ash.UUID.generate())
      end)

    {:ok, credential} = Credentials.rotate(source.host.id, 3600)

    {:ok, session} =
      ProvisionerControl.open_execution(credential.token, %{
        session_id: Ash.UUID.generate(),
        machine_id: source.host.machine_id
      })

    %{vm: vm, relocation: relocation, owner: owner, token: credential.token, session: session}
  end

  @spec journey(context(), [pos_integer()], [pos_integer()]) :: boolean()
  defp journey(c, stop_unknowns, start_unknowns) do
    alias Marshall.Compute.{Relocation, RelocationCoordinator, RelocationRevocations}

    {:ok, _} =
      Marshall.Compute.cancel_relocation(%{relocation_id: c.relocation.id}, actor: c.owner)

    message = %{session_id: c.session["session_id"], epoch: c.session["epoch"], results: []}
    {:ok, %{"commands" => [wire]}} = RelocationRevocations.exchange(c.token, message)
    {:ok, revoke} = OverallsProtocol.RelocationRevocation.command(wire)

    {:ok, _} =
      RelocationRevocations.exchange(c.token, %{
        message
        | results: [Map.take(revoke, [:id, :placement_id, :execution_epoch])]
      })

    holds = Enum.sort_by(Ledger.read!(Reservation, vm_id: c.vm.id), & &1.id)
    assert {:ok, :restoring_source} = RelocationCoordinator.advance(c.relocation.id)

    for attempt <- 0..3 do
      [relocation] = Ledger.read!(Relocation, id: c.relocation.id)
      [stop] = Ledger.read!(Operation, id: relocation.cancellation_stop_operation_id)
      for _ <- 1..Enum.at(stop_unknowns, attempt), do: restoration_outcome(c, stop, :unknown)
      assert {:ok, :restoring_source} = RelocationCoordinator.advance(relocation.id)

      assert [%{cancellation_start_operation_id: nil}] =
               Ledger.read!(Relocation, id: relocation.id)

      restoration_outcome(c, stop, :stopped)
      assert {:ok, :restoring_source} = RelocationCoordinator.advance(relocation.id)
      [relocation] = Ledger.read!(Relocation, id: relocation.id)
      [start] = Ledger.read!(Operation, id: relocation.cancellation_start_operation_id)
      assert start.generation == stop.generation + 1
      for _ <- 1..Enum.at(start_unknowns, attempt), do: restoration_outcome(c, start, :unknown)
      assert {:ok, :restoring_source} = RelocationCoordinator.advance(relocation.id)
      restoration_outcome(c, start, :failed, false)
      assert {:ok, :restoring_source} = RelocationCoordinator.advance(relocation.id)
      assert [%{generation: same_generation}] = Ledger.read!(VirtualMachine, id: c.vm.id)
      assert same_generation == start.generation
      failure = restoration_outcome(c, start, :failed)
      expected = if attempt < 3, do: :restoring_source, else: :restoration_retry_exhausted
      assert {:ok, ^expected} = RelocationCoordinator.advance(relocation.id)
      [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)
      assert length(vm.crash_restart_times) == min(attempt + 1, 3)
      assert vm.generation == start.generation + if(attempt < 3, do: 1, else: 0)
      execution = Map.merge(message, %{report: nil, acknowledgements: [], outcomes: [failure]})
      assert {:ok, _} = ProvisionerControl.exchange_execution(c.token, execution)
      assert {:ok, ^expected} = RelocationCoordinator.advance(relocation.id)
      assert [^vm] = Ledger.read!(VirtualMachine, id: c.vm.id)
      assert holds == Enum.sort_by(Ledger.read!(Reservation, vm_id: c.vm.id), & &1.id)
      [retained] = Ledger.read!(Relocation, id: relocation.id)

      assert retained.source_restored_at == nil and retained.finished_at == nil and
               retained.committed_at == nil
    end

    [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)
    now = Ledger.now()

    Ledger.intent!(vm, %{
      crash_restart_times: List.duplicate(DateTime.add(now, 60), 3)
    })

    assert {:ok, :restoration_retry_exhausted} = RelocationCoordinator.advance(c.relocation.id)

    Ledger.intent!(vm, %{
      crash_restart_times: List.duplicate(DateTime.add(now, -601), 3)
    })

    assert {:ok, :restoring_source} = RelocationCoordinator.advance(c.relocation.id)
    [relocation] = Ledger.read!(Relocation, id: c.relocation.id)
    [stop] = Ledger.read!(Operation, id: relocation.cancellation_stop_operation_id)
    restoration_outcome(c, stop, :stopped)
    assert {:ok, :restoring_source} = RelocationCoordinator.advance(relocation.id)
    [relocation] = Ledger.read!(Relocation, id: relocation.id)
    [start] = Ledger.read!(Operation, id: relocation.cancellation_start_operation_id)
    restoration_outcome(c, start, :running)
    assert {:ok, :source_restored_pending_cleanup} = RelocationCoordinator.advance(relocation.id)
    [restored] = Ledger.read!(Relocation, id: relocation.id)
    assert restored.source_restored_at != nil and restored.finished_at == nil
    assert holds == Enum.sort_by(Ledger.read!(Reservation, vm_id: c.vm.id), & &1.id)
  end

  @spec restoration_outcome(context(), Operation.t(), :unknown | :stopped | :failed | :running) ::
          map()
  defp restoration_outcome(c, operation, state),
    do: restoration_outcome(c, operation, state, true)

  @spec restoration_outcome(
          context(),
          Operation.t(),
          :unknown | :stopped | :failed | :running,
          boolean()
        ) :: map()
  defp restoration_outcome(c, operation, state, disk_present) do
    [vm] = Ledger.read!(VirtualMachine, id: c.vm.id)

    outcome = %{
      id: Ash.UUID.generate(),
      vm_id: vm.id,
      placement_id: operation.placement_id,
      execution_epoch: operation.execution_epoch,
      generation: operation.generation,
      operation_id: operation.id,
      sequence: vm.outcome_sequence + 1,
      state: state,
      compute_empty: state in [:stopped, :failed],
      disk_present: disk_present,
      cleanup_complete: false,
      reason:
        case state do
          :failed -> :execution_failed
          :unknown -> :unknown
          _ -> :none
        end
    }

    execution = %{
      session_id: c.session["session_id"],
      epoch: c.session["epoch"],
      report: nil,
      acknowledgements: [],
      outcomes: []
    }

    assert {:ok, _} = ProvisionerControl.exchange_execution(c.token, execution)

    assert {:ok, _} =
             ProvisionerControl.exchange_execution(c.token, %{execution | outcomes: [outcome]})

    outcome
  end
end
