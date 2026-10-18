defmodule Lilly.VM.ActorDeferralTest do
  # Log capture is global, so this module runs alone rather than beside the
  # asynchronous actor tests that also produce retryable results.
  use ExUnit.Case, async: false
  import Hegel
  import Hegel.Gen
  alias Lilly.Control.Store
  alias Lilly.VM.Actor
  @moduletag :tmp_dir
  @metadata [:event, :vm_id, :placement_id, :reason]
  @reasons [:private_services_unavailable, :storage_busy, :network_unavailable]

  @type step :: {:retry, atom()} | :observed | :actor_restart

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

  # @cc [owner:ghuntley,label:verification;observability] actor-deferral-transition-model
  # Generated retry/outcome/actor-restart histories MUST emit
  # vm.execution_deferred exactly when the reference model sees a new
  # consecutive deferral reason, and deferrals MUST never append an outcome.
  # This exercises actor logic with a controlled executor; native readiness of
  # private services is covered by the brady-fleet machine scenario.
  @tag :hegel
  test "deferral diagnostics follow reason transitions across outcomes and actor restarts",
       context do
    Hegel.check(
      fn ->
        steps =
          draw(
            "steps",
            list_of(
              frequency([
                {6, tuple({constant(:retry), member_of(@reasons)})},
                {1, constant(:observed)},
                {1, constant(:actor_restart)}
              ]),
              min_length: 1,
              max_length: 12
            )
          )

        id = Lilly.UUID.generate()
        directory = Path.join(context.tmp_dir, Lilly.UUID.generate())
        File.mkdir!(directory)
        File.chmod!(directory, 0o700)
        {:ok, store} = Store.open(directory, id, 3)
        start = command(id)
        {:ok, :stored} = Store.accept(store, start)

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
            actor = Overalls.HegelFixtures.start_supervised!({Actor, options}, id: id)
            assert_receive {:vm_actor_ready, ^id, ^actor, _}, 2000
            Enum.reduce(steps, actor, &apply_step(&1, &2, start, options))
            stop_supervised!(id)
          end)

        emitted =
          log
          |> String.split("\n")
          |> Enum.filter(&(&1 =~ "vm.execution_deferred" and &1 =~ "vm_id=#{id}"))
          |> Enum.map(fn line ->
            [_, reason] = Regex.run(~r/reason=([a-z_]+)/, line)
            String.to_existing_atom(reason)
          end)

        assert emitted == expected(steps)
      end,
      test_cases: 100
    )
  end

  @spec apply_step(step(), pid(), map(), keyword()) :: pid()
  defp apply_step(:actor_restart, _actor, start, options) do
    id = start.placement_id
    stop_supervised!(id)
    flush_executions()
    replacement = start_supervised!({Actor, options}, id: id)
    assert_receive {:vm_actor_ready, ^id, ^replacement, _}, 2000
    replacement
  end

  defp apply_step(step, actor, start, _options) do
    id = start.placement_id
    before = Actor.status(actor).outcome_sequence
    Actor.reconcile(actor)
    assert_receive {:execute, worker, ^start, _}, 2000
    monitor = Process.monitor(worker)

    result =
      case step do
        {:retry, reason} -> {:retry, reason}
        :observed -> {:ok, running()}
      end

    send(worker, {:result, result})
    assert_receive {:DOWN, ^monitor, :process, ^worker, :normal}, 2000
    _ = :sys.get_state(actor)

    case step do
      {:retry, _} ->
        assert Actor.status(actor).outcome_sequence == before
        refute_received {:vm_actor_outcome, ^id, ^actor, _}

      :observed ->
        assert_receive {:vm_actor_outcome, ^id, ^actor, %{state: :running}}, 2000
    end

    actor
  end

  # A periodic tick may have started work that the stopped actor killed.
  @spec flush_executions() :: :ok
  defp flush_executions do
    receive do
      {:execute, _, _, _} -> flush_executions()
    after
      0 -> :ok
    end
  end

  # Reference model: a deferral is reported when its reason differs from the
  # previous consecutive deferral; an outcome or a fresh actor re-arms it.
  @spec expected([step()]) :: [atom()]
  defp expected(steps) do
    {emitted, _} =
      Enum.reduce(steps, {[], nil}, fn
        {:retry, reason}, {emitted, reason} -> {emitted, reason}
        {:retry, reason}, {emitted, _} -> {[reason | emitted], reason}
        _, {emitted, _} -> {emitted, nil}
      end)

    Enum.reverse(emitted)
  end

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
