defmodule Marshall.Compute.RelocationReadinessState do
  @moduledoc "Durable readiness deadline after exact physical activation evidence."
  alias Marshall.Compute.{
    Ledger,
    Operation,
    PhysicalOutcome,
    ReadinessRequest,
    Relocation,
    SourcePermitRequest,
    VirtualMachine
  }

  # @cc [owner:ghuntley,label:recovery;capacity] readiness-retains-source-until-guest-proof
  # advance_locked!/2 requires host-before-VM serialization. A running workload
  # gets one deadline measured from its retained activation outcome; retries do
  # not reset it. Only stopped workloads can become ready without a boot receipt.
  # Timeout or changed activation is terminal for this request and releases no holds.
  @spec advance_locked!(Relocation.t(), VirtualMachine.t() | nil) :: ReadinessRequest.t() | nil
  def advance_locked!(relocation, vm) do
    result =
      if relocation.committed_at != nil do
        case Ledger.read!(ReadinessRequest, id: relocation.activation_operation_id) do
          [request] ->
            reconcile(request, relocation, vm)

          [] ->
            case activation(relocation, vm) do
              {:ok, outcome} ->
                [import] = Ledger.read!(SourcePermitRequest, id: relocation.import_request_id)

                request =
                  Ledger.create!(ReadinessRequest, :record, %{
                    id: relocation.activation_operation_id,
                    relocation_id: relocation.id,
                    vm_id: vm.id,
                    generation: relocation.activation_generation,
                    descriptor: import.descriptor,
                    requires_boot: relocation.original_state == :running,
                    deadline_at: DateTime.add(outcome.inserted_at, timeout_ms!(), :millisecond)
                  })

                reconcile(request, relocation, vm)

              _ ->
                nil
            end
        end
      end

    sync_phase(relocation, result, vm)
    result
  end

  defp sync_phase(relocation, request, vm) do
    [current] = Ledger.read!(Relocation, id: relocation.id)

    if current.phase == :checking_destination do
      cond do
        request != nil and request.status == :ready ->
          Ledger.update!(current, :confirm_readiness, %{})

        request != nil and request.status == :failed ->
          Ledger.update!(current, :fail_readiness, %{})

        vm != nil and vm.generation == current.activation_generation and
            vm.observed_state in [:failed, :unknown] ->
          Ledger.update!(current, :fail_activation, %{})

        true ->
          :ok
      end
    end
  end

  defp reconcile(%{status: :pending, requires_boot: false} = request, relocation, vm) do
    if match?({:ok, _}, activation(relocation, vm)),
      do: Ledger.update!(request, :ready, %{completed_at: Ledger.now()}),
      else: fail(request, :activation_changed)
  end

  defp reconcile(%{status: :pending} = request, relocation, vm) do
    cond do
      DateTime.compare(Ledger.now(), request.deadline_at) != :lt -> fail(request, :timeout)
      not match?({:ok, _}, activation(relocation, vm)) -> fail(request, :activation_changed)
      true -> request
    end
  end

  defp reconcile(request, _, _), do: request

  defp fail(request, reason),
    do: Ledger.update!(request, :fail, %{failure_reason: reason, completed_at: Ledger.now()})

  # @cc [owner:ghuntley,label:security;recovery] readiness-exact-physical-activation
  # activation/2 MUST bind current VM placement/epoch/generation and state to the
  # relocation's exact completed activation operation and immutable physical
  # outcome. Acknowledgement, imported bytes or operation status alone do not suffice.
  @spec activation(Relocation.t(), VirtualMachine.t() | nil) ::
          {:ok, PhysicalOutcome.t()} | :error
  def activation(_, nil), do: :error

  def activation(relocation, vm) do
    state = relocation.original_state

    with true <-
           relocation.committed_at != nil and vm.archived_at == nil and
             vm.current_placement_id == relocation.destination_placement_id and
             vm.execution_epoch == relocation.destination_epoch and
             vm.generation == relocation.activation_generation and
             vm.desired_state == state and vm.observed_state == state,
         [operation] <- Ledger.read!(Operation, id: relocation.activation_operation_id),
         true <-
           operation.status == :completed and operation.initiator == :relocation and
             operation.relocation_id == relocation.id and
             operation.placement_id == vm.current_placement_id and
             operation.execution_epoch == vm.execution_epoch and
             operation.generation == vm.generation and
             operation.kind == if(state == :running, do: :start, else: :stop),
         [outcome] <- Ledger.read!(PhysicalOutcome, id: operation.completion_outcome_id),
         {:ok, evidence} <- OverallsProtocol.Execution.outcome(outcome.observation),
         true <-
           outcome.host_id == relocation.destination_host_id and
             evidence.operation_id == operation.id and
             evidence.vm_id == vm.id and evidence.placement_id == vm.current_placement_id and
             evidence.execution_epoch == vm.execution_epoch and
             evidence.generation == vm.generation and
             evidence.state == state and evidence.disk_present and
             evidence.compute_empty == (state == :stopped),
         do: {:ok, outcome},
         else: (_ -> :error)
  end

  # @cc [owner:ghuntley,label:recovery;security] ready-placement-survives-later-lifecycle
  # Under VM serialization, retained readiness for the exact committed activation
  # MUST survive later generations on the same destination placement/epoch. Later
  # stop or failure MUST NOT strand source cleanup. Pending/failed readiness and
  # changed placement/epoch MUST never establish this permission.
  @spec ready?(Relocation.t(), VirtualMachine.t()) :: boolean()
  def ready?(relocation, vm) do
    relocation.committed_at != nil and vm.archived_at == nil and
      vm.current_placement_id == relocation.destination_placement_id and
      vm.execution_epoch == relocation.destination_epoch and
      vm.generation >= relocation.activation_generation and
      match?(
        [%{status: :ready, relocation_id: id, generation: generation}]
        when id == relocation.id and generation == relocation.activation_generation,
        Ledger.read!(ReadinessRequest, id: relocation.activation_operation_id)
      )
  end

  @doc "Under VM serialization, withhold destination terminals until guest readiness."
  @spec terminal_allowed?(VirtualMachine.t()) :: boolean()
  def terminal_allowed?(vm) do
    case Ledger.read!(Relocation, vm_id: vm.id, finished_at: [is_nil: true]) do
      [] -> true
      [%{committed_at: nil}] -> true
      [relocation] -> ready?(relocation, vm)
    end
  end

  defp timeout_ms! do
    case Application.get_env(:marshall, :relocation_readiness_timeout_ms, 120_000) do
      value when is_integer(value) and value in 1..600_000 -> value
      _ -> Ledger.rollback(:invalid_readiness_configuration)
    end
  end
end
