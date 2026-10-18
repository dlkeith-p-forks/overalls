defmodule Lilly.Lifecycle.RecoveryHistoryTest do
  use ExUnit.Case, async: true
  import Hegel
  import Hegel.Gen
  alias Lilly.Control.{Client, Config, Runtime, Store}
  alias Lilly.Host.{Lock, PrivateFiles}
  alias Lilly.VM.{Actor, Journal}
  @moduletag :tmp_dir
  @type actor_entry :: %{pid: pid(), command: OverallsProtocol.Execution.command()}
  @type actors :: %{String.t() => actor_entry()}

  defmodule PausedExecutor do
    @moduledoc false
    @behaviour Lilly.VM.Executor

    # @cc [owner:ghuntley,label:verification] recovery-effect-observer
    # Reconciliation MUST report only execution identifiers and remain blocked
    # until cleanup. A dispatch MUST NOT be counted as native execution evidence.
    @impl true
    @spec reconcile(pid(), OverallsProtocol.Execution.command(), %{
            running_epoch: non_neg_integer(),
            running_generation: non_neg_integer()
          }) ::
            {:retry, :storage_busy}
    def reconcile(owner, command, _history) do
      send(owner, {:recovery_effect, self(), command.placement_id, command.generation})

      receive do
        :finish -> {:retry, :storage_busy}
      end
    end
  end

  # @cc [owner:ghuntley,label:verification;recovery;observability] authenticated-recovery-independent-diagnostics
  # Restored actors MUST resume current physical reconciliation on authenticated
  # control connection without a diagnostic sender. This actor fixture does not
  # establish native VMM execution, TLS authentication or a full Runtime startup.
  @tag :hegel
  test "restored actor effects resume without a diagnostic sender", %{tmp_dir: root} do
    check all(
            actor_count <- integer(1..3),
            transitions <- member_of([1, 64, 65, 80]),
            test_cases: 4
          ) do
      directory = Path.join(root, Lilly.UUID.generate())
      :ok = PrivateFiles.directory(directory)
      host = Lilly.UUID.generate()
      {:ok, store} = Store.open(directory, host, 3)
      commands = prepare_backlogs(store, actor_count, transitions)
      {:ok, supervisor} = Supervisor.start_link([], strategy: :one_for_one)

      try do
        actors = start_actors(supervisor, store, commands)

        {:ok, client} =
          Client.new("https://example.test", host, host <> ":" <> String.duplicate("a", 43),
            machine_id: "sha256:" <> String.duplicate("a", 64)
          )

        config = %Config{client: client, state_dir: directory, cgroup_path: directory, pools: []}
        session = %{session_id: Lilly.UUID.generate(), epoch: 1, pools: []}
        task = Task.async(fn -> {:ok, session} end)

        state = %{
          phase: :connecting,
          actors: actors,
          config: config,
          session: nil,
          exchange_task: task,
          failures: 0,
          last_error: nil
        }

        for {_, entry} <- actors, do: refute(:sys.get_state(entry.pid).active)
        reference = task.ref
        assert_receive {^reference, result}, 2000

        assert {:noreply, %{phase: :connected} = connected} =
                 Runtime.handle_info({reference, result}, state)

        refute Map.has_key?(connected, :audit_ready)
        refute Map.has_key?(connected, :lifecycle_audit)

        for {placement, entry} <- actors do
          generation = entry.command.generation
          assert_receive {:recovery_effect, task_pid, ^placement, ^generation}, 2000
          actor = :sys.get_state(entry.pid)
          assert actor.task.pid == task_pid
          assert actor.active
        end
      after
        Supervisor.stop(supervisor)
      end
    end
  end

  @spec prepare_backlogs(Store.t(), pos_integer(), pos_integer()) :: [
          OverallsProtocol.Execution.command()
        ]
  defp prepare_backlogs(store, count, backlog) do
    for _ <- 1..count do
      command = command(store.host_id, backlog)
      directory = Path.join([Path.dirname(store.path), "actors", command.placement_id])
      :ok = PrivateFiles.directory(Path.dirname(directory))
      {:ok, lock} = Lock.acquire(directory)

      try do
        {:ok, journal} =
          Journal.open(directory, command.host_id, command.vm_id, command.placement_id)

        if backlog > 1 do
          Enum.reduce(1..(backlog - 1), journal, fn generation, journal ->
            {:ok, next} = Journal.attempt(journal, %{command | generation: generation})
            next
          end)
        end
      after
        :ok = Lock.release(lock)
      end

      {:ok, :stored} = Store.accept(store, command)
      command
    end
  end

  @spec command(String.t(), pos_integer()) :: OverallsProtocol.Execution.command()
  defp command(host, generation) do
    value = %{
      id: Lilly.UUID.generate(),
      host_id: host,
      vm_id: Lilly.UUID.generate(),
      owner_id: "0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f",
      placement_id: Lilly.UUID.generate(),
      pool_id: Lilly.UUID.generate(),
      execution_epoch: 1,
      generation: generation,
      kind: :start,
      image_id: "sha256:" <> String.duplicate("a", 64),
      slot: 2,
      architecture: :x86_64,
      profile: :customer,
      vcpu: 1,
      memory_bytes: 536_870_912,
      disk_bytes: 2_147_483_648
    }

    {:ok, validated} =
      OverallsProtocol.Execution.command(OverallsProtocol.Execution.encode_command(value))

    validated
  end

  @spec start_actors(Supervisor.supervisor(), Store.t(), [OverallsProtocol.Execution.command()]) ::
          actors()
  defp start_actors(supervisor, store, commands) do
    Map.new(commands, fn command ->
      options = [
        store: store,
        placement_id: command.placement_id,
        owner: self(),
        executor: {PausedExecutor, self()}
      ]

      {:ok, actor} =
        Supervisor.start_child(supervisor, %{
          id: command.placement_id,
          start: {Actor, :start_link, [options]},
          restart: :temporary
        })

      receive do
        {:vm_actor_ready, placement, ^actor, nil} when placement == command.placement_id -> :ok
      after
        2000 -> flunk("restored actor did not report readiness")
      end

      {command.placement_id, %{pid: actor, command: command}}
    end)
  end
end
