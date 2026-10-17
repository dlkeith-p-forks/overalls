defmodule Lilly.VM.ActorFailureEventTest do
  # Log capture is global, so this module runs alone rather than beside the
  # asynchronous actor tests that also record failed outcomes.
  use ExUnit.Case, async: false
  use ExUnitProperties
  alias Lilly.Control.Store
  alias Lilly.VM.Actor
  @moduletag :tmp_dir
  @metadata [:event, :vm_id, :placement_id, :reason]
  @reasons [:execution_failed, :crashed]

  @type step :: {:failed, atom()} | :observed | :actor_restart | :newer_command
  @type key :: {pos_integer(), :failed | :running, atom()}

  defmodule ControlledExecutor do
    @behaviour Lilly.VM.Executor
    @impl true
    def reconcile(owner, command, history) do
      send(owner, {:execute, self(), command, history})

      receive do
        {:result, result} -> result
      end
    end
  end

  # @cc [owner:ghuntley,label:verification;observability] actor-failure-event-model
  # Generated histories of repeated failed observations (a failed placement
  # whose desired state stays running is re-driven every tick), recoveries,
  # actor restarts and newer commands MUST emit vm.failed exactly when the
  # reference model sees a newly recorded failed outcome: once per
  # generation/reason until a recovery or a newer command, never once per
  # reconcile, and a repeated failure MUST NOT append a durable outcome.
  property "vm.failed follows recorded failed outcomes, not reconcile ticks", context do
    check all(
            steps <-
              list_of(
                frequency([
                  {6, tuple({constant(:failed), member_of(@reasons)})},
                  {1, constant(:observed)},
                  {1, constant(:actor_restart)},
                  {1, constant(:newer_command)}
                ]),
                min_length: 1,
                max_length: 12
              ),
            max_runs: 15
          ) do
      id = Lilly.UUID.generate()
      directory = Path.join(context.tmp_dir, Lilly.UUID.generate())
      File.mkdir!(directory)
      File.chmod!(directory, 0o700)
      {:ok, store} = Store.open(directory, id, 3)
      first = command(id)
      {:ok, :stored} = Store.accept(store, first)

      options = [
        store: store,
        vm_id: id,
        placement_id: id,
        execution_epoch: 1,
        owner: self(),
        executor: {ControlledExecutor, self()}
      ]

      log =
        ExUnit.CaptureLog.capture_log([metadata: @metadata], fn ->
          actor = start_supervised!({Actor, options}, id: id)
          assert_receive {:vm_actor_ready, ^id, ^actor, _}, 2000

          Enum.reduce(steps, {actor, first}, fn step, {actor, current} ->
            apply_step(step, actor, current, store, options)
          end)

          stop_supervised!(id)
        end)

      emitted =
        log
        |> String.split("\n")
        |> Enum.filter(&(&1 =~ "vm.failed" and &1 =~ "vm_id=#{id}"))
        |> Enum.map(fn line ->
          [_, reason] = Regex.run(~r/reason=([a-z_]+)/, line)
          String.to_existing_atom(reason)
        end)

      assert emitted == expected(steps)
    end
  end

  @spec apply_step(step(), pid(), map(), Store.t(), keyword()) :: {pid(), map()}
  defp apply_step(:actor_restart, _actor, current, _store, options) do
    id = current.placement_id
    stop_supervised!(id)
    flush_executions()
    replacement = start_supervised!({Actor, options}, id: id)
    assert_receive {:vm_actor_ready, ^id, ^replacement, _}, 2000
    {replacement, current}
  end

  defp apply_step(:newer_command, actor, current, store, _options) do
    newer = %{
      current
      | id: Lilly.UUID.generate(),
        kind: :start,
        generation: current.generation + 1
    }

    {:ok, :stored} = Store.accept(store, newer)
    {actor, newer}
  end

  defp apply_step(step, actor, current, _store, _options) do
    id = current.placement_id
    before = Actor.status(actor).outcome_sequence
    recorded = recorded(actor)
    Actor.reconcile(actor)
    assert_receive {:execute, worker, ^current, _}, 2000
    monitor = Process.monitor(worker)

    observation =
      case step do
        {:failed, reason} -> failed(reason)
        :observed -> running()
      end

    send(worker, {:result, {:ok, observation}})
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2000
    _ = :sys.get_state(actor)
    state = observation.state
    assert_receive {:vm_actor_outcome, ^id, ^actor, %{state: ^state}}, 2000

    # Re-observing the same failure leaves the durable outcome untouched.
    if recorded == key(current, observation),
      do: assert(Actor.status(actor).outcome_sequence == before),
      else: assert(Actor.status(actor).outcome_sequence == before + 1)

    {actor, current}
  end

  @spec recorded(pid()) :: key() | nil
  defp recorded(actor) do
    case :sys.get_state(actor).journal.outcome do
      nil -> nil
      outcome -> {outcome.generation, outcome.state, outcome.reason}
    end
  end

  @spec key(map(), map()) :: key()
  defp key(command, observation), do: {command.generation, observation.state, observation.reason}

  # A periodic tick may have started work that the stopped actor killed.
  @spec flush_executions() :: :ok
  defp flush_executions do
    receive do
      {:execute, _, _, _} -> flush_executions()
    after
      0 -> :ok
    end
  end

  # Reference model: the journal keeps the last recorded outcome across actor
  # restarts; a failure is reported when it differs from that outcome by
  # generation or reason, or follows a recorded recovery.
  @spec expected([step()]) :: [atom()]
  defp expected(steps) do
    {emitted, _, _} =
      Enum.reduce(steps, {[], nil, 1}, fn
        {:failed, reason}, {emitted, {generation, :failed, reason}, generation} ->
          {emitted, {generation, :failed, reason}, generation}

        {:failed, reason}, {emitted, _, generation} ->
          {[reason | emitted], {generation, :failed, reason}, generation}

        :observed, {emitted, _, generation} ->
          {emitted, {generation, :running, :none}, generation}

        :newer_command, {emitted, last, generation} ->
          {emitted, last, generation + 1}

        :actor_restart, accumulator ->
          accumulator
      end)

    Enum.reverse(emitted)
  end

  @spec failed(atom()) :: map()
  defp failed(reason),
    do: %{
      state: :failed,
      compute_empty: true,
      disk_present: true,
      cleanup_complete: false,
      reason: reason
    }

  @spec running() :: map()
  defp running,
    do: %{
      state: :running,
      compute_empty: false,
      disk_present: true,
      cleanup_complete: false,
      reason: :none
    }

  @spec command(String.t()) :: map()
  defp command(id),
    do: %{
      id: Lilly.UUID.generate(),
      vm_id: id,
      owner_id: "0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f",
      placement_id: id,
      execution_epoch: 1,
      host_id: id,
      pool_id: id,
      image_id: "sha256:" <> String.duplicate("a", 64),
      slot: 2,
      generation: 1,
      kind: :provision,
      architecture: :x86_64,
      profile: :customer,
      vcpu: 1,
      memory_bytes: 536_870_912,
      disk_bytes: 2_147_483_648
    }
end
