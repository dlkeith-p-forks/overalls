defmodule Lilly.VM.Journal do
  @moduledoc "Actor-owned durable execution history and latest unacknowledged physical outcome."
  alias OverallsProtocol.Execution
  alias Lilly.Host.PrivateFiles
  @maximum 9_223_372_036_854_775_807
  @current_keys ~w(acknowledged attempted_epoch attempted_generation host_id outcome phase placement_id running_epoch running_generation sequence version vm_id)
  @enforce_keys [:directory, :host_id, :vm_id, :placement_id]
  defstruct [
    :directory,
    :host_id,
    :vm_id,
    :placement_id,
    :outcome,
    phase: "idle",
    sequence: 0,
    attempted_epoch: 0,
    attempted_generation: 0,
    running_epoch: 0,
    running_generation: 0,
    acknowledged: true
  ]

  @type t :: %__MODULE__{
          phase: String.t(),
          directory: Path.t(),
          host_id: OverallsProtocol.uuid(),
          vm_id: OverallsProtocol.uuid(),
          placement_id: OverallsProtocol.uuid(),
          attempted_epoch: non_neg_integer(),
          running_epoch: non_neg_integer(),
          outcome: Execution.outcome() | nil,
          sequence: non_neg_integer(),
          attempted_generation: non_neg_integer(),
          running_generation: non_neg_integer(),
          acknowledged: boolean()
        }

  @doc "The caller must own the actor journal lock throughout use."
  # @cc [owner:ghuntley,label:assumption;recovery] journal-lock-and-identity
  # Callers of open/4 MUST hold the exclusive actor-directory lock throughout journal use.
  # Existing malformed or differently bound host/VM/placement state must fail instead of being replaced with
  # a fresh journal. Only the current lifecycle envelope is accepted.
  @spec open(Path.t(), OverallsProtocol.uuid(), OverallsProtocol.uuid(), OverallsProtocol.uuid()) ::
          {:ok, t()} | {:error, atom()}
  def open(directory, host, vm, placement) do
    with true <-
           OverallsProtocol.uuid?(host) and OverallsProtocol.uuid?(vm) and
             OverallsProtocol.uuid?(placement),
         :ok <- PrivateFiles.directory(directory) do
      journal = %__MODULE__{
        directory: directory,
        host_id: host,
        vm_id: vm,
        placement_id: placement
      }

      case File.lstat(Path.join(directory, "journal.json")) do
        {:error, :enoent} -> persist(journal)
        {:ok, _} -> read(journal)
        _ -> {:error, :invalid_execution_journal}
      end
    else
      _ -> {:error, :invalid_execution_journal}
    end
  end

  # @cc [owner:ghuntley,label:recovery] journal-monotonic-execution-authority
  # attempt/2 MUST retain the greatest epoch/generation pair for this placement.
  # An older epoch MUST fail even when it carries a higher generation; renewal
  # MUST NOT rewrite the epoch of previously confirmed running history.
  @spec attempt(t(), Execution.command()) :: {:ok, t()} | {:error, atom()}
  def attempt(journal, command) do
    cond do
      not matches?(journal, command) ->
        {:error, :vm_identity_conflict}

      revision(command) < attempted_revision(journal) ->
        {:error, :stale_generation}

      revision(command) == attempted_revision(journal) ->
        {:ok, journal}

      true ->
        persist(%{
          journal
          | phase: attempt_phase(command.kind),
            attempted_epoch: command.execution_epoch,
            attempted_generation: command.generation
        })
    end
  end

  # @cc [owner:ghuntley,label:recovery] outcome-durable-idempotent-facts
  # record/3 MUST persist a validated outcome before returning it for delivery, preserving its
  # event ID and sequence for identical facts. Stale epoch/generation pairs must fail and changed facts must
  # advance the sequence without wraparound.
  @spec record(t(), Execution.command(), map()) :: {:ok, t()} | {:error, atom()}
  def record(journal, command, observation) do
    facts =
      Map.merge(observation, %{
        vm_id: command.vm_id,
        placement_id: command.placement_id,
        execution_epoch: command.execution_epoch,
        operation_id: command.id,
        generation: command.generation
      })

    cond do
      not matches?(journal, command) or revision(command) != attempted_revision(journal) ->
        {:error, :stale_generation}

      journal.outcome != nil and Map.drop(journal.outcome, [:id, :sequence]) == facts ->
        {:ok, journal}

      journal.sequence >= @maximum ->
        {:error, :outcome_sequence_exhausted}

      true ->
        outcome = Map.merge(facts, %{id: Lilly.UUID.generate(), sequence: journal.sequence + 1})

        with {:ok, ^outcome} <- Execution.outcome(Execution.encode_outcome(outcome)) do
          persist(%{
            journal
            | phase: Atom.to_string(outcome.state),
              outcome: outcome,
              sequence: outcome.sequence,
              acknowledged: false,
              running_epoch:
                if(outcome.state == :running,
                  do: command.execution_epoch,
                  else: journal.running_epoch
                ),
              running_generation:
                if(outcome.state == :running,
                  do: command.generation,
                  else: journal.running_generation
                )
          })
        end
    end
  end

  # @cc [owner:ghuntley,label:recovery] acknowledgements-cannot-clear-newer-outcomes
  # acknowledge/2 MUST mark only the current matching outcome ID as acknowledged; a delayed
  # acknowledgement for a replaced outcome must leave the newer pending outcome available for
  # replay.
  @spec acknowledge(t(), [OverallsProtocol.uuid()]) :: {:ok, t()} | {:error, atom()}
  def acknowledge(journal, ids) do
    if journal.outcome != nil and journal.outcome.id in ids and not journal.acknowledged,
      do: persist(%{journal | acknowledged: true}),
      else: {:ok, journal}
  end

  @spec pending(t()) :: Execution.outcome() | nil
  def pending(%{acknowledged: true}), do: nil
  def pending(journal), do: journal.outcome

  defp read(journal) do
    with {:ok, bytes} <- PrivateFiles.read_secret(Path.join(journal.directory, "journal.json")),
         {:ok, data} <- decode_journal(bytes),
         %{
           "version" => 3,
           "host_id" => host,
           "vm_id" => vm,
           "placement_id" => placement,
           "attempted_epoch" => attempted_epoch,
           "running_epoch" => running_epoch,
           "sequence" => sequence,
           "attempted_generation" => attempted,
           "running_generation" => running,
           "acknowledged" => ack,
           "outcome" => encoded_outcome
         } <- data,
         true <-
           host == journal.host_id and vm == journal.vm_id and placement == journal.placement_id,
         true <-
           Enum.all?(
             [sequence, attempted_epoch, attempted, running_epoch, running],
             &(is_integer(&1) and &1 in 0..@maximum)
           ),
         true <-
           is_boolean(ack) and
             valid_revision?(attempted_epoch, attempted) and
             valid_revision?(running_epoch, running) and
             {running_epoch, running} <= {attempted_epoch, attempted} and
             (encoded_outcome != nil or running == 0),
         {:ok, outcome} <- decode_outcome(encoded_outcome),
         true <- coherent?(journal, sequence, {attempted_epoch, attempted}, ack, outcome),
         {:ok, phase} <- lifecycle_state(data["phase"]) do
      {:ok,
       %{
         journal
         | phase: phase,
           sequence: sequence,
           attempted_epoch: attempted_epoch,
           attempted_generation: attempted,
           running_epoch: running_epoch,
           running_generation: running,
           acknowledged: ack,
           outcome: outcome
       }}
    else
      _ -> {:error, :invalid_execution_journal}
    end
  end

  defp decode_journal(bytes) do
    with {:ok, data} <- Lilly.Lifecycle.Journal.decode(bytes),
         true <- Enum.sort(Map.keys(data)) == @current_keys do
      {:ok, data}
    else
      _ -> {:error, :invalid_execution_journal}
    end
  end

  defp lifecycle_state(phase) when is_binary(phase) do
    with {:ok, _state} <-
           Lilly.Lifecycle.Journal.state(Lilly.Lifecycle.Execution, %{"phase" => phase}),
         do: {:ok, phase}
  end

  defp lifecycle_state(_phase), do: {:error, :invalid_execution_journal}

  defp decode_outcome(nil), do: {:ok, nil}
  defp decode_outcome(value), do: Execution.outcome(value)
  defp coherent?(_vm, 0, _attempted, true, nil), do: true

  defp coherent?(journal, sequence, attempted, _ack, outcome) when not is_nil(outcome),
    do:
      outcome.vm_id == journal.vm_id and outcome.placement_id == journal.placement_id and
        outcome.sequence == sequence and revision(outcome) <= attempted

  defp coherent?(_, _, _, _, _), do: false

  defp matches?(journal, command),
    do:
      command.host_id == journal.host_id and command.vm_id == journal.vm_id and
        command.placement_id == journal.placement_id

  defp revision(command), do: {command.execution_epoch, command.generation}
  defp attempted_revision(journal), do: {journal.attempted_epoch, journal.attempted_generation}
  defp valid_revision?(0, 0), do: true
  defp valid_revision?(epoch, generation), do: epoch > 0 and generation > 0

  defp persist(journal) do
    body = %{
      "version" => 3,
      "phase" => journal.phase,
      "host_id" => journal.host_id,
      "vm_id" => journal.vm_id,
      "placement_id" => journal.placement_id,
      "attempted_epoch" => journal.attempted_epoch,
      "running_epoch" => journal.running_epoch,
      "sequence" => journal.sequence,
      "attempted_generation" => journal.attempted_generation,
      "running_generation" => journal.running_generation,
      "acknowledged" => journal.acknowledged,
      "outcome" => if(journal.outcome, do: Execution.encode_outcome(journal.outcome))
    }

    with {:ok, lock} <- audit_lock(journal.directory) do
      try do
        with :ok <-
               Lilly.Lifecycle.Journal.write(
                 Lilly.Lifecycle.Execution,
                 journal.directory,
                 "journal.json",
                 body
               ),
             do: {:ok, journal}
      after
        Lilly.Host.Lock.release(lock)
      end
    end
  end

  # @cc [owner:ghuntley,label:recovery;concurrency] journal-audit-lock-contention
  # Authoritative placement writers share audit-lock.
  # Journal writes MUST wait a bounded two seconds for it and report
  # :journal_busy (contention, nothing written) rather than a write failure;
  # callers treat :journal_busy as retryable (ADR-0140: contention is never
  # evidence). Contention MUST NOT stop the VM actor or fence the host.
  defp audit_lock(directory) do
    case Lilly.Host.Lock.acquire(Path.join(directory, "audit-lock"), 2000) do
      {:ok, lock} -> {:ok, lock}
      {:error, :host_already_owned} -> {:error, :journal_busy}
      error -> error
    end
  end

  defp attempt_phase(kind) when kind in [:provision, :start], do: "starting"
  defp attempt_phase(:pause), do: "pausing"
  defp attempt_phase(:resume), do: "resuming"
  defp attempt_phase(:stop), do: "stopping"
  defp attempt_phase(:delete), do: "deleting"
  defp attempt_phase(:resize), do: "resizing"
end
