defmodule Lilly.VM.ActorPreemptionTest do
  use ExUnit.Case, async: false
  alias Lilly.Control.Store
  alias Lilly.Execution
  alias Lilly.VM.Actor
  @id "33333333-3333-4333-8333-333333333333"
  @moduletag :tmp_dir

  # Reports each reconcile to the test and either commits first or blocks
  # until told what to do; a start never reaches its commit on its own.
  defmodule Executor do
    @behaviour Lilly.VM.Executor

    @impl true
    def reconcile(owner, command, history) do
      send(owner, {:execute, self(), command.generation, command.kind})

      receive do
        :commit -> send(owner, {:committed, self(), history.commit.()})
      end

      receive do
        :finish -> {:ok, observation(command)}
      end
    end

    @impl true
    def watch_target(_owner, _command), do: :error

    defp observation(%{kind: :stop}),
      do: %{
        state: :stopped,
        compute_empty: true,
        disk_present: true,
        cleanup_complete: false,
        reason: :none
      }

    defp observation(_command),
      do: %{
        state: :running,
        compute_empty: false,
        disk_present: true,
        cleanup_complete: false,
        reason: :none
      }
  end

  setup %{tmp_dir: dir} do
    File.chmod!(dir, 0o700)
    {:ok, store} = Store.open(dir, @id, 3)

    command = %{
      id: Lilly.UUID.generate(),
      vm_id: @id,
      owner_id: "0f0f0f0f-0f0f-4f0f-8f0f-0f0f0f0f0f0f",
      placement_id: @id,
      execution_epoch: 1,
      host_id: @id,
      pool_id: @id,
      image_id: "sha256:" <> String.duplicate("a", 64),
      slot: 2,
      generation: 1,
      kind: :start,
      architecture: :x86_64,
      profile: :customer,
      vcpu: 1,
      memory_bytes: 536_870_912,
      disk_bytes: 2_147_483_648
    }

    {:ok, :stored} = Store.accept(store, command)
    view = :"preempt_view_#{System.unique_integer([:positive])}"
    start_supervised!({OverallsProtocol.View, name: view})
    :ok = Execution.runtime_connected(view)
    :ok = Execution.intent(view, command)

    actor =
      start_supervised!(
        {Actor,
         store: store,
         placement_id: @id,
         owner: self(),
         executor: {Executor, self()},
         view: view,
         watch_executable: nil}
      )

    %{store: store, command: command, actor: actor}
  end

  defp newer(ctx, kind) do
    stop = %{ctx.command | id: Lilly.UUID.generate(), generation: 2, kind: kind}
    {:ok, :stored} = Store.accept(ctx.store, stop)
    Actor.reconcile(ctx.actor)
  end

  # @cc [owner:ghuntley,label:verification;recovery] preemption-before-commit-only
  # A newer command MUST kill a task that has not been granted its launch
  # commit and start the newer command; a task that holds its commit MUST
  # finish, and a superseded task asking to commit MUST be refused.
  test "a newer stop preempts an uncommitted start and runs at once", ctx do
    Actor.reconcile(ctx.actor)
    assert_receive {:execute, first, 1, :start}, 2000
    ref = Process.monitor(first)

    newer(ctx, :stop)
    assert_receive {:DOWN, ^ref, :process, ^first, :killed}, 2000
    assert_receive {:execute, second, 2, :stop}, 2000
    send(second, :commit)
    assert_receive {:committed, ^second, :ok}, 2000
    send(second, :finish)
    assert_receive {:vm_actor_outcome, @id, _, %{state: :stopped}}, 2000
  end

  test "a committed start is not preempted; a superseded commit is refused", ctx do
    Actor.reconcile(ctx.actor)
    assert_receive {:execute, first, 1, :start}, 2000
    send(first, :commit)
    assert_receive {:committed, ^first, :ok}, 2000

    newer(ctx, :stop)
    ref = Process.monitor(first)
    refute_receive {:DOWN, ^ref, :process, ^first, _}, 300
    send(first, :finish)
    assert_receive {:execute, second, 2, :stop}, 2000

    # The stop's own commit is granted; a stale command's request is refused.
    assert {:error, :preempted} =
             GenServer.call(ctx.actor, {:commit_launch, ctx.command})

    send(second, :commit)
    assert_receive {:committed, ^second, :ok}, 2000
    send(second, :finish)
  end
end
